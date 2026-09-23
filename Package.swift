// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "captive-watchdog",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CaptiveKit", targets: ["CaptiveKit"]),
        .executable(name: "captive-watchdog", targets: ["captive-watchdog"]),
    ],
    targets: [
        .target(name: "CaptiveKit"),
        .executableTarget(name: "captive-watchdog", dependencies: ["CaptiveKit"]),
        .testTarget(
            name: "CaptiveKitTests",
            dependencies: ["CaptiveKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
