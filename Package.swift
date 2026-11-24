// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacTop",
    platforms: [.macOS("26.4")],
    products: [
        .library(name: "MacTopCore", targets: ["MacTopCore"]),
        .library(name: "MacTopSystem", targets: ["MacTopSystem"]),
        .executable(name: "MacTop", targets: ["MacTopApp"])
    ],
    targets: [
        .target(name: "MacTopCore"),
        .target(name: "MacTopSystem", dependencies: ["MacTopCore"]),
        .executableTarget(name: "MacTopApp", dependencies: ["MacTopCore", "MacTopSystem"]),
        .testTarget(name: "MacTopCoreTests", dependencies: ["MacTopCore"]),
        .testTarget(name: "MacTopSystemTests", dependencies: ["MacTopSystem"]),
        .testTarget(name: "MacTopAppTests", dependencies: ["MacTopApp"])
    ],
    swiftLanguageModes: [.v5]
)
