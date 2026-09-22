// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: AppKit, AVAudioEngine taps and Apple Events callbacks
// don't fit strict Swift 6 concurrency checking without a lot of ceremony.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Bolo",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic: command model, phrase parser, model fallback, grounding guard.
        .target(name: "BoloCore", swiftSettings: v5),
        // The menu-bar app: notch panel, push-to-talk, speech, skills.
        .executableTarget(name: "Bolo", dependencies: ["BoloCore"], swiftSettings: v5),
        .testTarget(name: "BoloCoreTests", dependencies: ["BoloCore"], swiftSettings: v5),
    ]
)
