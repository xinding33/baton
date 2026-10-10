// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "BatonCore"),
        .executableTarget(name: "Baton", dependencies: ["BatonCore"]),
        .testTarget(name: "BatonCoreTests", dependencies: ["BatonCore"]),
        .testTarget(name: "BatonTests", dependencies: ["Baton"]),
    ]
)
