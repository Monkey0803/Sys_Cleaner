# 只读遍历基准

此目录不接入 App。`ScanBenchmark matched` 与 Rust `shared`/`local` 分别以 1、4、8 个工作线程遍历；`production` 调用现有空间扫描器，始终使用 App 的 4 线程实现。Rust `local` 按目录分派任务，在工作线程内汇总后合并；`shared` 逐项更新共享结果，用来区分语言和汇总方式的影响。

`production-rust` 是后续集成实验：Rust helper 遍历并输出文件清单，Swift 核对云端占位状态并复用空间分析的汇总逻辑。它只在命令行传入 `--helper` 后启用；App 不传此选项。集成实验的实测记录见 [results/PROTOTYPE.md](results/PROTOTYPE.md)。

遍历规则：根目录内同卷、跳过符号链接及名为 `.Trash` 的目录、硬链接按路径计数；目录容量在遍历完成后向父目录汇总。统计逻辑字节数与 `st_blocks × 512` 磁盘占用。云端占位文件不属于本地对照范围；接入 App 前必须保留 App 现有规则。

## 准备

```sh
swift build -c release --product ScanBenchmark
$HOME/.cargo/bin/cargo build --release --manifest-path Benchmarks/Rust/Cargo.toml
$HOME/.cargo/bin/cargo test --manifest-path Benchmarks/Rust/Cargo.toml
swift test
```

集成实验的可复跑命令（在受测目录之外写清单，两个命令使用相同的排除路径）：

```sh
ROOT="$HOME/Documents/YostarWork/Git"
swift build -c release --product ScanBenchmark
$HOME/.cargo/bin/cargo build --release --manifest-path Benchmarks/Rust/Cargo.toml --bin space_helper
.build/release/ScanBenchmark production "$ROOT" 4 --manifest > /tmp/sys-cleaner-swift.json
.build/release/ScanBenchmark production-rust "$ROOT" 4 --helper Benchmarks/Rust/target/release/space_helper --manifest > /tmp/sys-cleaner-rust.json
cmp /tmp/sys-cleaner-swift.json /tmp/sys-cleaner-rust.json
/usr/bin/time -l .build/release/ScanBenchmark production "$ROOT" 4 > /dev/null
/usr/bin/time -l .build/release/ScanBenchmark production-rust "$ROOT" 4 --helper Benchmarks/Rust/target/release/space_helper > /dev/null
```

## 验证与测量

```sh
python3 Benchmarks/run.py --verify-only
python3 Benchmarks/run.py --output /tmp/sys-cleaner-benchmark.json
# 若另一个任务持续改写 Github/HM/HarmonyRss，可明确排除并记录范围：
python3 Benchmarks/run.py --root "$HOME/Documents/YostarWork/Github" \
  --exclude "$HOME/Documents/YostarWork/Github/HM/HarmonyRss" \
  --output /tmp/sys-cleaner-github.json
```

脚本先在临时目录核对深层目录、符号链接、硬链接、`.Trash`、不可读目录和取消，再以 `hdiutil` 挂载并卸载临时 HFS+ 映像验证跨卷边界，最后逐目录比较 Swift、Rust 和现有空间扫描器的文件数、目录数、容量及每个目录的汇总。结果一致才开始计时，每种实现/线程数测首次及随后 5 次，交替顺序串行运行。`/usr/bin/time -l` 给出峰值常驻内存；首次仅表示本次序列的首次运行，不表示严格冷缓存。

测量期间不要编辑受测目录或并行执行其他扫描。如果目录内容变化，脚本会在验证或计时阶段中止，应待目录稳定后从头重跑。结果文件必须写在受测目录之外，完成后再复制到仓库。可用 `--root PATH` 重复指定个别目录；默认使用 `~/Documents/YostarWork/Github` 和 `~/Documents/YostarWork/Git`。本次 `Github/HM/HarmonyRss` 因持续外部构建而以 `--exclude` 在所有实现中统一排除，此范围记录在 JSON 的 `exclusions` 字段。所有程序只读，不执行删除。
