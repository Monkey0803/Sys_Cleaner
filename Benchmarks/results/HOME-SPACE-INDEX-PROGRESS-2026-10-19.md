# 空间分析目录索引与进度合并实测（2026-10-19）

基线为 `dc567b3` 的 release `ScanBenchmark production`；新版为本次 `Scanner.swift` 改动后的同一程序。两者均用 6 个 Swift 工作线程、相同遍历规则，串行扫描。命令和逐次原始数值见 [JSON](HOME-SPACE-INDEX-PROGRESS-2026-10-19.json)。首次与随后运行均受系统文件缓存影响，不能称为严格冷缓存测试。

## `/Users/huxiaohui`

| 顺序 | 版本 | 耗时 | 峰值常驻内存 | 文件 | 目录 |
| --- | --- | ---: | ---: | ---: | ---: |
| 1 | 基线 | 60.19 秒 | 1,201,356,800 字节 | 2,103,031 | 512,999 |
| 2 | 新版 | 51.67 秒 | 736,149,504 字节 | 2,102,329 | 512,921 |
| 3 | 基线 | 65.59 秒 | 1,052,901,376 字节 | 2,102,334 | 512,924 |
| 4 | 新版 | 48.92 秒 | 682,557,440 字节 | 2,102,346 | 512,922 |

基线中位耗时 **62.89 秒**、峰值内存 **1.13 GB**；新版分别为 **50.30 秒**、**0.71 GB**，约减少 **20%** 耗时和 **37%** 峰值内存。主目录有后台写入，逐次扫描结果不是同一快照，不能根据文件数差异判定实现差异。省时幅度只适用于该机器、该路径及本次环境。

这些耗时来自终端运行的同一生产 `FileScanner.scan` 代码，但终端和图形 App 的文件访问权限不同。重建后的 App 实际扫描 `/Users/huxiaohui` 得到约 **233 万个文件、596 GB**，而终端基准约 **210 万个文件、328 GB**；例如终端不能读取 `~/Library/Daemon Containers`，App 界面则显示其约 217 GB。因此上述百分比不能直接当成完整 App 扫描的提速幅度。App 的扫描进度、结果列表以及进入和返回 `Library` 文件夹已在运行窗口中检查；这次没有可比的旧版 App 运行时间和峰值内存记录。

## `~/Documents/YostarWork/Git`

5 轮基线与新版交替运行，中位耗时为 **1.25 → 1.20 秒**，峰值内存为 **49.4 → 40.9 MB**。这个较小目录的耗时波动明显，因此没有足够证据主张显著提速。修改进度更新前，基线与新目录索引版本的 `--manifest` 输出曾逐字节相同。最终版的可控目录验证通过；再次比较真实 Git 目录时，其他进程写入了该目录，清单不再属于同一快照。

## 改动与复跑

遍历时把父目录编号传给子项，用紧凑目录记录累计容量，避免长期同时保存完整目录 URL 数组与 URL 键字典。空间扫描的进度计数每 256 项或每个目录结束时合并更新；取消仍在每项之间检查。云端占位、跨卷、符号链接、硬链接及 `.Trash` 的判断保持原有路径。

```sh
swift build -c release --product ScanBenchmark
/usr/bin/time -l .build/release/ScanBenchmark production /Users/huxiaohui 6
/usr/bin/time -l .build/release/ScanBenchmark production /Users/huxiaohui/Documents/YostarWork/Git 6
python3 Benchmarks/run.py --verify-only
swift test
```

`swift test`：78 项执行，2 项因 Xcode/构建进程运行而跳过，0 失败。`run.py --verify-only` 的可控目录链接、硬链接、不可读目录、取消和跨卷检查通过；随后真实 `Github` 目录的 Rust/Swift 清单比较因并发写入而失败，不能当作算法差异证据。
