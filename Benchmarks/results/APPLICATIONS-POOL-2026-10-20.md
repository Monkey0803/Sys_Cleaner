# `/Applications`：缩短遍历临时对象存活时间（2026-10-20）

未改动版为 `fe85637`，候选版仅在并行目录遍历中每 256 个子项排空一次 `autoreleasepool`。两个版本均使用相同的 6 工作线程、云端占位判断及结果汇总规则；候选版没有启用 Rust helper。每次扫描只读。原始运行数值和实际 App RSS 采样见 [JSON](APPLICATIONS-POOL-2026-10-20.json)。

## 热点与选择

对未改动版 Debug App 扫描 `/Applications` 做了 45 秒 Time Profiler 采样。`FileSafety.isCloudPlaceholder` 位于约 **56.9%** 的 CPU 样本调用栈中，`FileSafety.metadata` 位于约 **12.0%**。扫描结束后的 malloc 堆约 99.7 MB，其中 `SpaceTree.Directory` 数组约 13.6 MB；进程 RSS 随后还会回落，不能把扫描峰值都归因于常驻目录索引。

没有省略云端检查。Apple 的 [下载状态定义](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)包括“已有本地副本但版本过期”；因此仅依据 `SF_DATALESS` 文件标志跳过查询，可能改变现有占位判断。候选改动只缩短遍历临时 Foundation 对象的存活时间。

## 生产扫描器：交替运行

同一路径的两版 Release `ScanBenchmark production /Applications 6` 交替运行。全部八轮均得到 **1,538,084 文件、254,096 目录、194,699,093,424 逻辑字节、170,757,705,728 占用字节、5,811 遗漏项**。目录在这组运行期间结果一致；首次运行不等于严格冷缓存。

| 版本 | 四轮耗时 | 两轮有峰值记录的 RSS |
| --- | --- | --- |
| 未改动版 | 31.94、33.46、34.77、29.58 秒 | 269.5、324.7 MB |
| 候选版 | 40.05、31.79、32.79、32.60 秒 | 119.4、121.8 MB |

两版耗时中位数均约 **32.7 秒**，没有稳定提速证据。两组可比较的内存样本显示候选版峰值显著降低；这项改动的明确收益是内存。

## 实际 Debug App

两版分别构建并打开，在空间分析页选择同一个 `/Applications` 后点击扫描。未改动版来自独立临时构建；结束后已关闭它并重新打开仓库 `DerivedData/Build/Products/Debug/Sys Cleaner.app`。界面三轮都显示 **1,538,084 项、194.7 GB、磁盘占用约 170.76 GB、至少 5,811 项未单列或未读取**。

| 版本与轮次 | 结果出现 | 起始 RSS | 峰值 RSS |
| --- | ---: | ---: | ---: |
| 未改动版，重启后 | 36.96 秒 | 122.3 MB | 461.9 MB |
| 候选版，重启后 | ≤47.56 秒 | 121.1 MB | 214.7 MB |
| 候选版，再次扫描 | 38.71 秒 | 116.8 MB | 273.1 MB |

候选版实际 App 峰值较本次未改动版低约 **41–54%**。第一轮候选版界面检查间隔较长，只能给完成时间上界；第二轮比未改动版慢约 1.75 秒，但单次差异不足以判定稳定速度变化。RSS 采样每轮在点击前启动，约每 0.1 秒请求一次 `ps`；采样间隔会受请求耗时影响。

## 验证与复跑

- `swift test`：79 项执行，2 项因 Xcode/构建进程活跃跳过，0 失败；新增超过 256 子项的大目录汇总测试。
- `xcodebuild -project SysCleaner.xcodeproj -scheme 'Sys Cleaner' -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build`：构建成功，候选版实际 App 扫描与结果浏览已检查。
- 两版统计完全一致；遍历仍逐项检查取消、符号链接、跨卷、硬链接、云端占位和 `.Trash`。

复跑终端扫描：`swift build -c release --product ScanBenchmark`，随后运行 `.build/release/ScanBenchmark production /Applications 6`。比较峰值内存时应在同一机器、相近后台负载下交替运行并记录每个进程的 `wait4` 最大 RSS；不要把 Release 命令行耗时直接与 Debug App 耗时比较。

## 2026-10-22 复核与后续提速实验

当前工作区仍为每 256 个子项释放一次临时对象的候选版。`swift test --disable-sandbox` 执行 86 项，0 失败；仓库 `DerivedData` 的 Debug App 构建成功并重新打开。实际 App 在 `/Applications` 扫描出 1,469,776 个文件、244,050 个文件夹、188,556,433,579 逻辑字节、166,340,460,544 已分配字节、5,371 个未单列或未读取项，和同日 Release 基准一致；目录进入及返回正常。约 0.15 秒间隔采样的 App 峰值 RSS 为 257,802,240 字节。这一轮没有同步运行旧版 App，不能单独用于计算改动幅度。

在相同的分批释放实现上，仅把空间扫描工作线程从 6 增加到 8，对 `/Applications` 按 6、8、8、6 顺序运行只读 Release 基准。四轮结果均与上述文件数、目录数和容量一致。6 线程分别耗时 29.265、32.627 秒，峰值 RSS 为 122,159,104、120,602,624 字节；8 线程分别耗时 29.300、31.989 秒，峰值 RSS 为 152,059,904、123,109,376 字节。没有稳定加速且一次峰值较高，因此恢复 6 线程。原始四轮输出见 [JSON](APPLICATIONS-WORKERS-2026-10-22.json)。

在同批 100,000 个 `/Applications` 文件上，原有两次 URL 属性查询、合并查询、`FileManager.isUbiquitousItem` 及复用属性键集合的三轮交替微基准均判定 0 个云端占位文件；耗时波动重叠，没有足够证据替换现有云端判断。没有跳过检查，因为 Apple 的下载状态还区分“本地副本已过期”，只看无数据标志会改变现有结果。
