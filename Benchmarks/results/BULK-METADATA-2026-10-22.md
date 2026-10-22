# 批量元数据读取实验（2026-10-22，未采用）

## 结论

保留分批枚举的低内存实现，不把本次 `getattrlistbulk` 原型接入 App。主目录部分轮次略快，但内容稳定的 Git 目录只相差约 1%，应用目录没有优势；现有证据不足以抵消底层记录解析与兼容处理的维护成本。没有切换到 Rust，也没有放宽云端、链接或跨卷规则。

| 数据集 / 构建 | 原分批枚举中位耗时 | 批量元数据原型中位耗时 | 轮数 / 说明 |
| --- | ---: | ---: | --- |
| `/Applications` / Release | 22.775 秒 | 22.970 秒 | 每版 2 次，交替运行，汇总相等 |
| `/Users/huxiaohui` / Release | 41.907 秒 | 39.881 秒 | 每版 3 次，主目录持续变化，系统负载上升 |
| `/Users/huxiaohui` / Debug | 43.363 秒 | 41.558 秒 | 每版 2 次，主目录持续变化；原版最后一轮更快 |
| `~/Documents/YostarWork/Git` / Release | 0.93 秒 | 0.92 秒 | 每版 5 次，所有汇总一致 |

Git 目录共 59,623 个文件、6,803 个目录，逻辑容量 11,451,896,948 字节，已分配容量 11,621,158,912 字节，无遗漏；每个目录的完整汇总也相等。Git 目录计时来自 `/usr/bin/time -l`，原始精度为 0.01 秒；1% 差距不能当作可靠加速。

主目录 Release 的峰值 RSS 中位数约为 148.2 MB 与 153.9 MB。主目录文件数、容量和遗漏数在后台写入期间变化，不能据此声称同一快照的加速；Debug 中位数也不能代替实际 App 窗口的计时。所有数据均为已运行过扫描后的测量，不称为冷缓存。

原始运行记录、二进制摘要与采样摘要见 [JSON](BULK-METADATA-2026-10-22.json)。本表的基线是已优化的分批枚举版本，不能与最初 `d19a3eb` 的内存比较混为一组。

## 采样发现

对分批枚举版主目录扫描取 12 秒线程栈样本，6 个工作线程共 27,834 个样本中约 15,879 个包含云端状态判断调用栈，其中出现 FileProvider 路径和元数据查询。另有 `lstat`、目录批量枚举及属性读取调用。这里是包含阻塞等待的线程栈样本，不能解释成精确的 CPU 时间百分比。

已知云盘根目录仍在进入前排除；根目录以外的占位文件检查仍保留。直接跳过这项安全检查可能改变扫描和删除边界，不作为本次性能优化。

## 原型及验证

- 每个工作线程复用 64 KiB 缓冲区，批量读取常规文件身份、时间、逻辑容量及分配容量；目录和属性不完整的条目使用相对目录描述符的查询回退。
- 保留符号链接拒绝、设备边界、云端状态及原有结果上限。Foundation 枚举仍作为不支持批量读取时的回退。
- 发现并修正了目录记录不包含文件专属属性的布局差异；增加截断记录、无效名称偏移和属性缺失检查。
- 原型测试覆盖 Unicode/特殊字符、硬链接、符号链接、稀疏文件及资源分支；全套 92 项测试通过。初版原型与分批枚举版在 `/Applications` 上的 244,050 个目录汇总一致；最终原型的 Git 目录完整汇总一致。
- 未对原型执行实际 App 交互验收，也未重新验证原型跨卷挂载样本；原型已移出生产源码，因此这些结果不构成上线验收。

## 复现原型

[独立补丁](../experiments/BULK-METADATA-2026-10-22.patch) 以 `d19a3eb` 为基点，包含分批枚举及批量读取原型。只在临时导出的副本应用，避免修改实际 App：

```sh
experiment_dir=$(mktemp -d /private/tmp/syscleaner-bulk-experiment.XXXXXX)
git archive d19a3eb Package.swift Sources Benchmarks/Swift Tests | tar -x -C "$experiment_dir"
patch_file="$PWD/Benchmarks/experiments/BULK-METADATA-2026-10-22.patch"
(cd "$experiment_dir" && git apply "$patch_file")
swift test --package-path "$experiment_dir" --disable-sandbox
swift build --package-path "$experiment_dir" -c release --product ScanBenchmark --disable-sandbox
/usr/bin/time -l "$experiment_dir/.build/release/ScanBenchmark" production /Users/huxiaohui 6
```

原型补丁只包含实现及其 4 项新增测试，不含当前分批枚举工作中的其他新增测试；因此临时基点副本的测试总数与当时工作区的 92 项不同。

对照版从当前工作区构建 `ScanBenchmark`；先用 `--manifest` 核对稳定目录完整输出，再不带 `--manifest` 交替计时。完整目录清单会额外占用内存，不用于 RSS 性能对照。不要并行执行扫描与构建。
