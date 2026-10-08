// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeedRAW",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeedRAW", targets: ["SpeedRAW"])
    ],
    targets: [
        .executableTarget(name: "SpeedRAW")
    ]
)
