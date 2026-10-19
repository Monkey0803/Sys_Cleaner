// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SysCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SysCleanerCore", targets: ["SysCleanerCore"]),
        .executable(name: "ScanBenchmark", targets: ["ScanBenchmark"])
    ],
    targets: [
        .target(name: "SysCleanerCore"),
        .executableTarget(name: "ScanBenchmark", dependencies: ["SysCleanerCore"],
                          path: "Benchmarks/Swift"),
        .testTarget(name: "SysCleanerCoreTests", dependencies: ["SysCleanerCore"])
    ]
)
