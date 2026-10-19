# 主目录 Swift 与 Rust 扫描对照（2026-10-19）

## 范围与方法

在 Apple M4、32 GiB 内存的本机上，对 `/Users/huxiaohui` 串行执行只读扫描，均使用 4 个工作线程。Swift 6.4；Rust `rustc`/`cargo` 1.99.1。`matched-local` 与 Rust `local` 均按目录派发任务、在线程内累加，统计同卷文件、逻辑字节和 `st_blocks × 512`；跳过符号链接、`.Trash` 和 `FileManager` 隐藏的 `._` AppleDouble 伴生文件，硬链接按路径计数。完整模式还自底向上汇总目录容量。计时使用 release 构建和 `/usr/bin/time -l`，最大常驻内存单位为字节。

主目录一直有日志和应用数据写入，因此相邻扫描不是同一文件系统快照。只把结果完全一致的静态子目录用作严格正确性对照；主目录计时只说明这台机器上的近似开销，不能当作端到端 App 加速幅度。逐次原始计时、峰值内存和统计结果见 [HOME-SWIFT-RUST-2026-10-19.json](HOME-SWIFT-RUST-2026-10-19.json)；下表摘录主目录的完整遍历数字。

## 结果

| 顺序 | 实现 | 耗时 | 最大常驻内存 | 文件 | 目录 | 逻辑字节 | 磁盘占用字节 | 遗漏 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | Rust `local` | 21.87 秒 | 442,695,680 | 2,108,343 | 535,767 | 369,490,156,134 | 334,468,292,608 | 525 |
| 2 | Swift `matched-local` | 27.46 秒 | 465,829,888 | 2,108,343 | 535,767 | 369,490,332,528 | 334,468,419,584 | 525 |
| 3 | Swift `matched-local` | 27.53 秒 | 456,572,928 | 2,108,345 | 535,767 | 369,490,879,470 | 334,469,525,504 | 525 |
| 4 | Rust `local` | 21.89 秒 | 435,027,968 | 2,108,344 | 535,767 | 369,489,960,152 | 334,468,546,560 | 525 |

两次耗时的中位数为 Swift 27.50 秒、Rust 21.88 秒：**Rust 的实验遍历与汇总约缩短 20%**。容量差异来自扫描期间的写入，第二组文件数也变化了 1 项。此前未对齐 `._` 伴生文件的 Rust 数据不得用于严格性能结论。`--no-totals` 的单次拆分测量分别为 Swift 25.10 秒、Rust 20.02 秒；这两次在修正 `._` 规则前运行，只用于定位 Swift 基准原先的汇总开销，不能用于正确性对照。

在内容稳定的 `~/Documents/YostarWork/Git`，Swift 与 Rust 都返回 **59,759 个文件、6,731 个目录、11,510,416,035 逻辑字节、11,679,997,952 磁盘占用字节、0 遗漏**，每个目录的汇总完全一致。五组交替的完整扫描全部保持这些结果；热缓存中位耗时 Swift 0.210 秒、Rust 0.120 秒。这个小目录的热缓存比例不能外推到主目录。CoreSimulator 中含 `._` 文件的静态目录也已逐目录验证一致。

当前 App 的 Swift `production` 空间扫描在同一路径的一次独立运行耗时 60.14 秒，最大常驻内存 1,848,229,888 字节，统计 2,108,218 个文件、535,742 个目录。此模式还执行云端占位检查、生成展示项、更新进度和结果上限计数；其中 49,515 个“遗漏”包含未单列项目，不能与遍历基准的 525 个读取遗漏直接比较。原本的 Swift `matched` 基准用逐文件共享锁和逐层路径排序，曾测得 95.53 秒；采样发现排序及构造未标记目录的 URL 又触发额外 `lstat`，这些开销属于基准程序，不属于当前 App。修正后才有上表的可比结果。

为定位生产扫描的额外成本，在相同的 Swift 遍历上做了阶段实验：`matched --no-totals` 共享汇总 24.00 秒、`matched-local --no-totals` 局部汇总 24.17 秒，文件数均为 2,108,346，说明当前并无明显的逐项锁竞争收益。局部汇总加上与生产代码相同的 `FileSafety.isCloudPlaceholder` 后两次为 **48.91 秒和 49.19 秒**，峰值内存分别为 958,595,072 和 954,515,456 字节；比无云端检查的一次测量多约 25 秒。这不是严格配对的文件快照，但指出云端元数据查询是主要候选热区。让 `FileManager` 预取 `.isUbiquitousItemKey` 的一次实验反而耗时 **73.09 秒**、峰值内存 1,437,040,640 字节，因此不推荐直接采用属性预取。

现有 Rust `space_helper` 在主目录仅生成 JSON 文件清单，就耗时 21.07 秒、峰值内存 860,340,224 字节，输出 **485,148,204 字节**。`RustSpaceScanner.read` 当前将整份输出读入内存并限制为 **256 MiB**，所以这份清单会被拒绝并回退 Swift；`isEligible` 还会因为主目录包含 `~/Library/CloudStorage` 或 `~/Library/Mobile Documents` 而直接拒绝 Rust。App 本身也没有启用 helper。本次没有测得“Rust 接入 App 后的主目录扫描时间”。

## 优化顺序

1. **优先处理云端占位检查。** 生产扫描逐项调用 `FileSafety.isCloudPlaceholder`，实验显示这是约 25 秒量级的热点。下一阶段先在 App 扫描路径加阶段计时，验证哪些目录或卷能证明不含云端占位文件，再考虑局部跳过或更廉价的判断方式。必须用 iCloud 与文件提供者的已下载、未下载和占位目录验证；不能仅凭本地基准省掉检查。简单的 `FileManager` 属性预取已实测更慢。
2. **再定位结果处理的额外成本。** 从约 49 秒的“遍历加云端检查”到约 60 秒的生产扫描还有展示项、进度和目录汇总等工作；需分别计时并保留结果上限及取消语义。共享锁与局部汇总的遍历耗时几乎相同，当前不应先改动锁策略。不要把实验基准的排序改动误当作 App 提速；App 已采用线性自底向上汇总。
3. **Rust 只作为下一阶段候选。** 若要接入，应改为有界流式协议，避免 485 MB JSON 和全量解码，同时在 Rust/Swift 边界保留云端占位、取消和遗漏规则。先通过静态目录与主目录的结果核对，再按既定门槛验证两个真实目录均稳定提速至少 25%、峰值内存增加不超过 15%。当前主目录实验遍历仅约 20% 收益且无法通过现有 helper，因此不应直接切换 App。

## 复跑

```sh
swift build -c release --product ScanBenchmark
$HOME/.cargo/bin/cargo build --release --manifest-path Benchmarks/Rust/Cargo.toml
python3 -c 'import sys; sys.path.insert(0, "Benchmarks"); import run; run.verify_fixture()'
/usr/bin/time -l .build/release/ScanBenchmark matched-local /Users/huxiaohui 4
/usr/bin/time -l .build/release/ScanBenchmark matched-local /Users/huxiaohui 4 --no-totals --check-cloud
/usr/bin/time -l .build/release/ScanBenchmark matched-local /Users/huxiaohui 4 --no-totals --check-cloud --prefetch-cloud
/usr/bin/time -l Benchmarks/Rust/target/release/sys-cleaner-traversal-bench local /Users/huxiaohui 4
/usr/bin/time -l .build/release/ScanBenchmark production /Users/huxiaohui 4
```

同一时间只运行一个扫描；把计时输出重定向到受测根目录之外。测量期间不要使用清理/删除功能。本报告的 `production` 60.14 秒数据基于 `0e5f851` 的 4 线程 App 扫描器；后续已单独测量并改为 6 线程，见 [HOME-SPACE-WORKERS-2026-10-19.md](HOME-SPACE-WORKERS-2026-10-19.md)。当前 `production` 的位置参数不控制空间扫描线程数，要复现本报告的 4 线程结果需构建原提交。
