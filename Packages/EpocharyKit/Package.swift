// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EpocharyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EpocharyKit", targets: ["EpocharyKit"]),
    ],
    targets: [
        .target(name: "EpocharyKit"),
        .testTarget(name: "EpocharyKitTests", dependencies: ["EpocharyKit"]),
    ]
)
