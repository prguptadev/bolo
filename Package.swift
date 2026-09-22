// swift-tools-version: 6.0
import PackageDescription

// Swift 5 language mode: AppKit, AVAudioEngine taps and Apple Events callbacks
// don't fit strict Swift 6 concurrency checking without a lot of ceremony.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Bolo",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Qwen3.5-4B on the GPU. MLX's Metal kernels only compile under xcodebuild, which
        // scripts/build-app.sh uses; a plain `swift build` links but can't run the model.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Pure logic: command model, phrase parser, hearing fixes, grounding guard. No UI, fully tested.
        .target(name: "BoloCore", swiftSettings: v5),
        // The menu-bar app: notch panel, push-to-talk, speech, skills, Qwen.
        .executableTarget(
            name: "Bolo",
            dependencies: [
                "BoloCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: v5),
        .testTarget(name: "BoloCoreTests", dependencies: ["BoloCore"], swiftSettings: v5),
    ]
)
