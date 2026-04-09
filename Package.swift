// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OnlyVoice",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.8"),
    ],
    targets: [
        .executableTarget(
            name: "OnlyVoice",
            dependencies: ["Starscream"],
            path: "Sources/OnlyVoice",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
