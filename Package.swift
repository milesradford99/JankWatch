// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JankWatch",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "JankWatch", targets: ["JankWatch"]),
        .executable(name: "jankctl", targets: ["jankctl"]),
        .executable(name: "jankprobe", targets: ["jankprobe"]),
        .library(name: "JankWatchCore", targets: ["JankWatchCore"]),
    ],
    targets: [
        // Pure logic. Foundation only, must keep compiling on Linux so it can be unit-tested anywhere.
        .target(name: "JankWatchCore"),
        // macOS-only system integration (sensors, samplers, actions, engine). Every file is wrapped in `#if os(macOS)`.
        .target(name: "JankWatchMac", dependencies: ["JankWatchCore"]),
        // The menu bar app.
        .executableTarget(name: "JankWatch", dependencies: ["JankWatchCore", "JankWatchMac"]),
        // Small helper run (optionally as root via an admin prompt) to act on processes owned by other users.
        .executableTarget(name: "jankctl", dependencies: ["JankWatchCore", "JankWatchMac"]),
        // Validation / diagnostics CLI used on real hardware (see docs/VALIDATION.md).
        .executableTarget(name: "jankprobe", dependencies: ["JankWatchCore", "JankWatchMac"]),
        .testTarget(name: "JankWatchCoreTests", dependencies: ["JankWatchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
