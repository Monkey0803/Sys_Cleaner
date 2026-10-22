# 空间扫描：降低峰值内存后调整并发（2026-10-22）

## 最终结果

保留 Swift 扫描器的有界分批枚举和倒序目录汇总，将空间扫描的固定 6 个工作线程改为按可用处理器数使用最多 8 个线程。Rust helper 未启用，文件内容不被读取；云端隔离、占位文件检查、跨卷、符号链接、硬链接、结果上限和删除复核规则保留。

以下是最终 Release 生产扫描器与已提交版本 `d19a3eb` 的独立对照。每个路径按旧版、新版、新版、旧版、旧版、新版顺序运行，每版取 3 次中位数：

| 路径 | 旧版耗时 | 新版耗时 | 耗时降幅 | 旧版峰值 RSS | 新版峰值 RSS | RSS 降幅 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/Applications` | 23.006 秒 | 20.618 秒 | 10.4% | 316.9 MB | 93.4 MB | 70.5% |
| `/Users/huxiaohui` | 41.315 秒 | 36.666 秒 | 11.3% | 880.1 MB | 171.3 MB | 80.5% |

MB 为十进制。数据来自同一机器、同一权限环境中的扫描基准进程；不是实际 App 端到端加速百分比，也不是所有扫描类别或所有机器的保证。

- 应用目录六轮统计完全一致：1,469,776 个文件、244,050 个目录、188,556,433,579 逻辑字节、166,340,460,544 已分配字节、5,371 个未单列或遗漏项。三轮新版均快于三轮旧版。
- 主目录持续被其他程序写入，文件数为 2,191,073–2,191,076，目录数为 524,066–524,069，容量和遗漏数略有变化。因此主目录数字是本机观察结果，不是同一静态快照的严格证明；不能把变化的文件数当成算法差异。
- `~/Documents/YostarWork/Git` 的旧版与最终新版完整目录汇总相同，提供稳定数据集的正确性对照。
- 两版都已在此前运行过，首次记录不等于冷缓存。最终对照期间未同时运行其他基准、构建或测试。

完整原始值、CPU 时间、源码/二进制摘要、并发筛选及 App 内存样本见 [JSON](SPACE-CONCURRENCY-2026-10-22.json)。

## 为什么选择 8 个线程

本机为 Apple M4，10 个物理/逻辑核心（4 个性能核心、6 个能效核心），32 GiB 内存。旧的整目录数组方式限制了增加并发的收益；有界分批枚举大幅降低了同时存活的临时对象，因此重新测试了 4、6、8、10、12 个线程。

主目录同一有界遍历的两轮筛选中：

| 线程数 | 耗时中位数 | 峰值 RSS 中位数 |
| ---: | ---: | ---: |
| 6 | 40.482 秒 | 153.5 MB |
| 8 | 36.973 秒 | 162.8 MB |
| 10 | 35.659 秒 | 179.6 MB |

8 线程比 6 线程约快 8.7%，峰值内存约增加 6.0%；10 线程只再节省约 1.3 秒，但增加约 17 MB。因此选择上限 8，且不超过系统报告的可用处理器数。增加并发会增加累计 CPU 时间；实际 App 中另行检查了扫描时切换页面和取消。没有添加用户可见的线程设置或持久缓存。

筛选阶段的应用目录确认组首条记录可能与一个小型 Swift 微基准编译末尾重叠，已明确排除。它不进入上方最终对照表；上表来自之后重新执行的完整独立测量。

## 保留和未采用的改动

- **保留**：浅层目录枚举每批最多处理 256 项，及时释放临时对象；倒序汇总目录容量；空间扫描上限 8 个工作线程。
- **未采用**：[批量元数据解析](BULK-METADATA-2026-10-22.md)、[分批加锁合并结果](BATCH-RESULTS-2026-10-22.md)。收益不稳定，已移出生产源码。
- **未采用**：把 `url.path` 改成直接文件系统路径表示。66,427 个路径的重复微基准约为 0.115–0.119 秒，几乎持平；首次运行的差距混入缓存影响，不据此改动 `FileSafety`。

## 验证

- `swift test --disable-sandbox`：88 项通过，0 失败。覆盖深层目录、跨批计数、隐藏项、`.Trash`、AppleDouble、链接、不可读目录、路径别名、结果上限及取消；取消测试确认已计入进度的文件不会丢失。
- 稳定 Git 目录的完整 JSON 汇总相等；应用目录最终版的逐目录汇总核对单列在 JSON 的 `validation.applicationsManifest` 中。
- 用临时 HFS+ 挂载卷验证：两版均只保留根目录、0 个文件，不进入另一设备；验证后成功卸载并清理。
- 按 `AGENTS.md` 构建仓库 `DerivedData`：构建通过。核实并关闭旧进程，重新打开 `DerivedData/Build/Products/Debug/Sys Cleaner.app`。
- 实际 App 完成 `/Users/huxiaohui` 扫描，显示 2,427,470 个文件、604.86 GB 逻辑容量、约 610.67 GB 磁盘占用及至少 64,690 个未单列或未读取项；界面保留部分结果和云端排除说明。
- 扫描中切换到大文件页面并返回，扫描继续；完成后进入 `Library` 并返回主目录；重新扫描后点击取消，进度消失并恢复“开始扫描”。取消到空闲观察间隔约 0.48 秒，含接口观察开销。
- 实际 App 按约 0.25 秒间隔采样，观察到峰值 RSS 306,593,792 字节（约 306.6 MB），短暂峰值可能漏采。此值没有同一轮旧版 App 对照，不据此计算 App 内存降幅。
- 28.8 秒观察时尚在扫描，48.6 秒观察时已完成；这是完成时间观察区间，不是精确端到端计时。

### App 与命令行的权限差异

本轮再次确认：命令行读取 `~/Library/Daemon Containers` 返回 `Operation not permitted`，App 则能读取该目录并显示约 217.33 GB。App 处理的数据比命令行基准更多，因此不能直接比较两者的总量、耗时或内存，也不能把上表百分比宣称为整个 App 的实际加速比例。

## 复跑

```sh
baseline_dir=$(mktemp -d /private/tmp/syscleaner-baseline.XXXXXX)
git archive d19a3eb Package.swift Sources Benchmarks/Swift Tests | tar -x -C "$baseline_dir"
swift build --package-path "$baseline_dir" -c release --product ScanBenchmark --disable-sandbox
swift build -c release --product ScanBenchmark --disable-sandbox

# 先核对稳定目录的完整汇总。
root=/Users/huxiaohui/Documents/YostarWork/Git
"$baseline_dir/.build/release/ScanBenchmark" production "$root" 6 --manifest > /private/tmp/syscleaner-before.json
.build/release/ScanBenchmark production "$root" 6 --manifest > /private/tmp/syscleaner-after.json
python3 -c 'import json; assert json.load(open("/private/tmp/syscleaner-before.json")) == json.load(open("/private/tmp/syscleaner-after.json"))'

# 再按旧、新、新、旧、旧、新的顺序测量；另将路径换成 /Users/huxiaohui。
/usr/bin/time -l "$baseline_dir/.build/release/ScanBenchmark" production /Applications 6
/usr/bin/time -l .build/release/ScanBenchmark production /Applications 6
```

`production` 的位置参数不会覆盖生产扫描器的工作线程配置：基点为 6，最终版按可用处理器数最多使用 8。不要带 `--manifest` 测量内存，因为完整目录清单会额外分配大量路径和字典。

如需复跑线程筛选，在当前源码的隔离副本应用 [并发实验补丁](../experiments/SPACE-CONCURRENCY-2026-10-22.patch)，再通过 `SCAN_BENCHMARK_WORKERS=6`、`8` 或 `10` 分别启动生产基准。该环境变量仅存在于实验补丁，正式 App 不读取它。所有基准只读，不执行清理或删除。
