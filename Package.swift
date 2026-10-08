// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VectorEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VectorEngine", targets: ["VectorEngine"]),
        .executable(name: "vectorize", targets: ["vectorize"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "VectorEngine"),
        .executableTarget(
            name: "vectorize",
            dependencies: ["VectorEngine", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "VectorEngineTests", dependencies: ["VectorEngine"]),
    ]
)
