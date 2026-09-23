// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "captive-watchdog",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CaptiveKit", targets: ["CaptiveKit"]),
        .executable(name: "captive-watchdog", targets: ["captive-watchdog"]),
        .executable(name: "CaptiveWatchdogApp", targets: ["CaptiveWatchdogApp"]),
    ],
    targets: [
        .target(name: "CaptiveKit"),
        .executableTarget(name: "captive-watchdog", dependencies: ["CaptiveKit"]),
        .executableTarget(name: "CaptiveWatchdogApp", dependencies: ["CaptiveKit"]),
        .testTarget(
            name: "CaptiveKitTests",
            dependencies: ["CaptiveKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
