// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTyping",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceTyping", targets: ["VoiceTyping"]),
        .library(name: "VoiceTypingCore", targets: ["VoiceTypingCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VoiceTypingCore",
            dependencies: [],
            path: "Sources/VoiceTypingCore"
        ),
        .executableTarget(
            name: "VoiceTyping",
            dependencies: ["VoiceTypingCore"],
            path: "Sources/VoiceTyping"
        ),
        .testTarget(
            name: "VoiceTypingTests",
            dependencies: ["VoiceTypingCore"],
            path: "Tests/VoiceTypingTests"
        )
    ]
)
