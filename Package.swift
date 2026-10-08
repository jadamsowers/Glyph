// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VectorEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VectorEngine", targets: ["VectorEngine"]),
    ],
    targets: [
        .target(name: "VectorEngine"),
        .testTarget(name: "VectorEngineTests", dependencies: ["VectorEngine"]),
    ]
)
