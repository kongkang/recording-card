// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WatchRecorderCore",
    platforms: [
        .iOS(.v15),
        .watchOS(.v10),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "WatchRecorderCore",
            targets: ["WatchRecorderCore"]
        ),
        .executable(
            name: "WatchRecorderCoreVerify",
            targets: ["WatchRecorderCoreVerify"]
        ),
    ],
    targets: [
        .target(
            name: "WatchRecorderCore",
            path: "Sources/WatchRecorderCore"
        ),
        .executableTarget(
            name: "WatchRecorderCoreVerify",
            dependencies: ["WatchRecorderCore"],
            path: "Sources/WatchRecorderCoreVerify"
        ),
        .testTarget(
            name: "WatchRecorderCoreTests",
            dependencies: ["WatchRecorderCore"],
            path: "Tests/WatchRecorderCoreTests"
        ),
    ]
)
