// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VoiceTyping",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceTyping", targets: ["VoiceTyping"]),
        .executable(name: "VoiceTypingIME", targets: ["VoiceTypingIME"]),
        .library(name: "VoiceTypingCore", targets: ["VoiceTypingCore"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VoiceTypingCore",
            dependencies: [],
            path: "Sources/VoiceTypingCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "VoiceTyping",
            dependencies: ["VoiceTypingCore"],
            path: "Sources/VoiceTyping"
        ),
        // Pano kullanmadan metin yazan görünmez giriş yöntemi (~/Library/Input Methods).
        .executableTarget(
            name: "VoiceTypingIME",
            dependencies: [],
            path: "Sources/VoiceTypingIME",
            linkerSettings: [.linkedFramework("InputMethodKit")]
        ),
        .testTarget(
            name: "VoiceTypingTests",
            dependencies: ["VoiceTypingCore"],
            path: "Tests/VoiceTypingTests"
        )
    ]
)
