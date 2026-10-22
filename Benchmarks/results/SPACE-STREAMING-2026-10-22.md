# 空间扫描：分批枚举与目录汇总（2026-10-22）

## 结论

本轮确认的收益是降低内存峰值，尚未证明稳定提速。扫描器保持 Swift 和 6 个工作线程，未启用 Rust helper。只读扫描范围、云端隔离、符号链接、跨卷和硬链接规则保持原样。

| 路径 | 已提交版本耗时中位数 | 候选耗时中位数 | 已提交版本峰值 RSS 中位数 | 候选峰值 RSS 中位数 | RSS 降幅 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `/Applications` | 24.117 秒 | 23.700 秒 | 324.2 MB | 93.5 MB | 71.2% |
| `/Users/huxiaohui` | 45.459 秒 | 43.348 秒 | 792.0 MB | 150.4 MB | 81.0% |

中位数均取同组每版 3 次运行；MB 为十进制。耗时差距分别为 1.7% 和 4.6%，样本波动重叠，不能承诺相应加速幅度。主目录持续有后台写入，文件数、容量及遗漏项不同，不具备同一静态快照的速度比较条件。

原始值、环境、二进制及源码摘要见 [JSON](SPACE-STREAMING-2026-10-22.json)。10 月 20 日的逐批排空临时对象实验和 10 月 22 日的 6/8 线程实验保留为独立历史记录，不与本表混合计算。

## 实现

- 并行遍历改用只枚举一层的 `DirectoryEnumerator`，每次处理最多 256 项并排空临时 Foundation 对象，避免先构建整个文件夹的 URL 数组。
- 每个目录仍交给既有任务队列；入队前保留原来的路径、元数据、卷和云端检查。每项处理前检查取消，读错误计入遗漏并继续处理可读项。
- 目录一定先于其子目录登记，因此按索引倒序汇总容量；移除子目录计数和额外的就绪数组。
- 保留默认属性预取。额外对照中，关闭预取在应用目录上未更快，主目录仅有小幅差异，没有足够证据采用。

[Apple 枚举接口文档](https://developer.apple.com/documentation/foundation/filemanager/enumerator(at:includingpropertiesforkeys:options:errorhandler:))说明错误处理器返回继续时可跳过错误项继续枚举。本轮最终代码在取消以外继续处理，不将单项错误变为整次扫描成功。

## 测量方法与边界

- 基线来自独立导出的 `d19a3eb`；两版均为 Release 的生产扫描器，6 线程，同一权限环境。
- 按基线、候选、候选、基线、基线、候选的顺序逐次执行；没有同时运行另一项扫描、编译或测试。
- 用单调时钟测端到端进程耗时，用 macOS `wait4` 的 `ru_maxrss` 记录峰值 RSS 字节数。首次测量不等于冷缓存。
- `/Applications` 六轮结果一致：1,469,776 个文件、244,050 个目录、188,556,433,579 逻辑字节、166,340,460,544 占用字节、5,371 个遗漏或未单列项。
- 主目录六轮目录数为 524,086，文件数为 2,190,501–2,190,515；仅据此确认内存改善，不声称结果属于同一静态快照。
- 主测量候选在枚举错误时停止当前浅层枚举器；最终版调整为除取消外继续。最终版另有一次两个路径的复查、可控样本及逐目录汇总核对，单列在 JSON 的 `finalValidation` 中。
- 使用的内存数字是扫描进程 RSS，不是系统总内存，也不是实际 App 窗口进程的内存。实际 App 验证另列。

## 复跑

在仓库根目录执行以下命令；基线放在主目录以外，避免将它加入主目录扫描结果。暂存和提交不是复跑步骤。

```sh
baseline_dir=$(mktemp -d /private/tmp/syscleaner-baseline.XXXXXX)
git archive d19a3eb Package.swift Sources Benchmarks/Swift Tests | tar -x -C "$baseline_dir"
swift build --package-path "$baseline_dir" -c release --product ScanBenchmark --disable-sandbox
swift build -c release --product ScanBenchmark --disable-sandbox

/usr/bin/time -l "$baseline_dir/.build/release/ScanBenchmark" production /Applications 6
/usr/bin/time -l .build/release/ScanBenchmark production /Applications 6
# 同一顺序交替重复，再将路径替换为 /Users/huxiaohui。

"$baseline_dir/.build/release/ScanBenchmark" production /Applications 6 --manifest > /private/tmp/syscleaner-baseline-manifest.json
.build/release/ScanBenchmark production /Applications 6 --manifest > /private/tmp/syscleaner-candidate-manifest.json
python3 -c 'import json; a=json.load(open("/private/tmp/syscleaner-baseline-manifest.json")); b=json.load(open("/private/tmp/syscleaner-candidate-manifest.json")); assert a == b; print("逐目录汇总一致")'
```

`--manifest` 会额外生成完整目录路径字典，仅用于一致性核对，不纳入常规扫描的内存比较。运行时应关闭其他扫描任务，避免同时编译。

## 验证

- 最终代码：`swift test --disable-sandbox`，88 项通过，0 失败。
- 覆盖大目录跨批计数、扫描中取消、不可读目录与可读同级项、隐藏文件、AppleDouble 旁文件、`.Trash`、路径别名及中文/特殊字符；既有深层汇总、链接、筛选和结果上限测试也通过。
- 已按 `AGENTS.md` 使用仓库 `DerivedData` 构建 `Sys Cleaner`，构建通过。
- 最终版本与已提交版本在可控样本上结果相等；最终 `/Applications` 的 244,050 个目录路径及逻辑/占用容量汇总全部相等。
- 实际关闭旧进程并打开 `DerivedData/Build/Products/Debug/Sys Cleaner.app`，进程命令行确认使用该产物。空间分析完成 `/Applications` 扫描，界面显示 1,469,776 项、188.56 GB、占用约 166.34 GB、至少 5,371 项未单列或未读取，与基准汇总一致。
- 已实际进入 `/Applications/Unity` 并返回 `/Applications`；切回主目录后启动扫描并点击取消，观察到进度消失、“开始扫描”恢复。窗口接口记录的取消至空闲观察间隔约 0.48 秒，含接口观察开销。
- 实际 Debug App 在扫描与显示结果期间按约 0.25 秒间隔采样，峰值 RSS 为 214,712,320 字节（约 214.7 MB）；采样可能漏掉更短瞬时峰值。本轮没有同一快照下的旧版 App 进程对照，不能将 CLI 的内存降幅直接套用到 App。
- 界面在启动后 24.5 秒时仍在扫描，44.8 秒时已显示结果；这是观察区间，不是精确扫描耗时。
- 目录切换时自动化连接曾超时；调用栈显示主线程空闲。连接恢复后完成主目录扫描取消验证，未将连接超时当作 App 卡死或验证通过。

## 后续

先保留并交付已验证的低内存遍历；速度工作仍未完成。下一轮应针对剩余的文件元数据和云端状态查询开销做生产扫描器采样，在稳定目录上逐项对照。此前增加线程、替换 URL 查询接口、复用目录 URL 或关闭属性预取没有同时给出稳定速度和内存收益，不作为本轮实现的一部分。

## 同日后续核对

- 已补充[批量元数据读取实验](BULK-METADATA-2026-10-22.md)与[分批合并结果实验](BATCH-RESULTS-2026-10-22.md)。两种候选未证明跨目录的稳定提速，均未保留在生产源码；原始数据和隔离复现补丁保留。
- 最终生产 `Scanner.swift` 恢复为本报告验证的分批枚举版本。取消测试进一步确认报告文件数等于触发取消时的进度文件数；88 项测试再次通过。
- 后续速度工作应继续细分文件属性与云端状态查询开销；当前结论仍是明确降低内存，而非已解决扫描速度问题。
- 最终复建再次通过，关闭旧进程并打开仓库 `DerivedData/Build/Products/Debug/Sys Cleaner.app`，进程路径已核实。实际启动主目录扫描可见进度，点击取消后进度消失且恢复“开始扫描”。选择 Git 目录进行浏览复查时，界面自动化连接连续超时，因此本次不重复宣称目录浏览通过；上文较早的相同扫描代码目录进出验证仍单列保留。

## 后续并发复测

完成上述低内存改动后，重新测量 4–12 线程并选择最多 8 线程。最终版与 `d19a3eb` 的新一轮完整对照已显示内存和耗时改善，详见 [空间扫描并发结果](SPACE-CONCURRENCY-2026-10-22.md)。本文件上方的 6 线程数据和阶段结论保留为历史记录，不与后续组混合计算。
