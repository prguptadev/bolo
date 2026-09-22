// swift-tools-version: 6.0
import PackageDescription

// Phase 0 speech comparison: Apple's on-device SpeechAnalyzer vs WhisperKit on the same
// recordings. Also proves WhisperKit builds with the Command Line Tools before it goes into Bolo.
let package = Package(
    name: "SpeechEval",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "speech-eval",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
