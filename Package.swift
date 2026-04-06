// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OnlyVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OnlyVoice",
            path: "Sources/OnlyVoice",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
