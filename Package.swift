// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "djay-hud",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "djay-hud", path: "Sources")
    ]
)
