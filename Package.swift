// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Walk",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WalkKit", targets: ["WalkKit"]),
        .executable(name: "walk", targets: ["walk"]),
    ],
    targets: [
        .target(name: "WalkKit"),
        .executableTarget(name: "walk", dependencies: ["WalkKit"]),
        .testTarget(name: "WalkKitTests", dependencies: ["WalkKit"]),
    ]
)
