// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "remind",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "remind", path: "Sources")
    ]
)
