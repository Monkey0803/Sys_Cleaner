// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SysCleaner",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SysCleanerCore", targets: ["SysCleanerCore"])],
    targets: [
        .target(name: "SysCleanerCore"),
        .testTarget(name: "SysCleanerCoreTests", dependencies: ["SysCleanerCore"])
    ]
)
