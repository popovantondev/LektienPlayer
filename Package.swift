// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "LektienOnlineUebersetzung",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PlayerCore", targets: ["PlayerCore"]),
        .executable(name: "LektienOnlineUebersetzung", targets: ["LektienOnlineUebersetzung"])
    ],
    targets: [
        .target(name: "PlayerCore", resources: [.process("Resources")]),
        .target(name: "PlayerMedia", dependencies: ["PlayerCore"]),
        .target(name: "PlayerLAN", dependencies: ["PlayerCore"], resources: [.copy("Web")]),
        .target(name: "PlayerTranscription", dependencies: ["PlayerCore", "PlayerMedia"]),
        .target(name: "PlayerExport", dependencies: ["PlayerCore", "PlayerMedia", "PlayerSpeech"]),
        .target(name: "PlayerTranslation", dependencies: ["PlayerCore"], resources: [.process("Resources")]),
        .target(name: "PlayerSpeech", dependencies: ["PlayerCore"], resources: [.copy("Resources/Engine"), .process("Resources/de.lproj"), .process("Resources/en.lproj"), .process("Resources/ru.lproj")]),
        .executableTarget(
            name: "LektienOnlineUebersetzung",
            dependencies: ["PlayerCore", "PlayerTranslation", "PlayerSpeech", "PlayerMedia", "PlayerTranscription", "PlayerExport", "PlayerLAN"], resources: [.process("Resources")]
        ),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore", "PlayerTranslation", "PlayerSpeech", "PlayerMedia", "PlayerTranscription", "PlayerExport", "PlayerLAN"]),
        .testTarget(name: "PlayerAppTests", dependencies: ["LektienOnlineUebersetzung", "PlayerCore"])
    ]
)
