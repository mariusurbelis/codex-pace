// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPace",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexPace", targets: ["CodexPace"])],
    targets: [
        .target(name: "QuotaCore"),
        .target(name: "CodexUsage", dependencies: ["QuotaCore"]),
        .executableTarget(name: "CodexPace", dependencies: ["QuotaCore", "CodexUsage"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "CodexUsageTests", dependencies: ["CodexUsage", "QuotaCore"]),
    ]
)
