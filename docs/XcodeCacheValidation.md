# Xcode 共享缓存重建验证

2026-10-19 以仓库的 **Sys Cleaner** scheme 和独立的 `~/Library/Caches/SysCleaner-XcodeRebuildProof.*` DerivedData 根目录运行两轮 Debug 构建。第一轮构建成功后，将生成的候选缓存目录移入同一测试目录的 `held` 文件夹，再执行 `clean build`；第二轮构建成功，所有被移走的候选目录均重新生成且含文件。以下文件数来自 Xcode 27.1（27A9269）的首轮手工样本。

| 目录 | 首轮文件数 | 重建后文件数 | 结论 |
| --- | ---: | ---: | --- |
| `CompilationCache.noindex` | 7 | 7 | 本次样本可重建 |
| `ModuleCache.noindex` | 75 | 75 | 本次样本可重建 |
| `SDKStatCaches.noindex` | 1 | 1 | 本次样本可重建 |
| `SDKExplicitPrecompiledModules` | 81 | 81 | 本次样本可重建 |
| `SymbolCache.noindex` | 未生成 | 未生成 | 未验证，保持只读 |

同一脚本分别以 `DEVELOPER_DIR` 指向机器上的 Xcode 26.3（17C529）、27.0（27A266a）、27.0 beta（27A5218g）、27.1（27A9269）和 27.2 beta（27B5019j）运行。五次均完成两轮构建并重建其首轮生成的候选缓存；26.3 未生成 `SDKExplicitPrecompiledModules`，其余四个版本生成并重建了上述四类。所有样本均未生成 `SymbolCache.noindex`，所以它保持只读。

运行 `scripts/verify-xcode-cache-rebuild.sh` 可在独立的测试目录重复验证；脚本结束时只将自己创建的测试目录移入废纸篓。结果仅证明这些 Xcode 与本项目的构建能重新生成实际出现的候选目录。默认 DerivedData 可能由多个 Xcode 版本共用；开发中的 Xcode 或构建进程、最近修改、符号链接、自定义位置和删除前内容变化仍需单独处理，不能把本次结果当作任意环境的安全删除许可。
