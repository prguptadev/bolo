import AVFoundation
import Foundation
import Speech

/// Streams the microphone into Apple's on-device SpeechAnalyzer while the key is held.
/// The microphone runs only between `start()` and `stop()`.
@MainActor
final class SpeechEngine {
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Contact names and nicknames, so "bhai" and "Priya" are recognised as words.
    var contextualStrings: [String] = []

    private let locale: Locale
    private var audio: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""

    init(localeIdentifier: String) {
        locale = Locale(identifier: localeIdentifier)
    }

    private var current: String {
        (finalized + " " + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() async throws {
        finalized = ""
        volatile = ""
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation

        // Start the microphone first so the first words aren't lost while the analyzer spins up.
        let audio = AVAudioEngine()
        let node = audio.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        let converter = format.flatMap { $0 == micFormat ? nil : AVAudioConverter(from: micFormat, to: $0) }
        let levelHandler = onLevel
        node.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in
            if let level = Self.rms(buffer) { Task { @MainActor in levelHandler?(level) } }
            if let converter, let format {
                if let converted = Self.convert(buffer, with: converter, to: format) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
        audio.prepare()
        try audio.start()
        self.audio = audio

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(200))
            try? await analyzer.setContext(context)
        }
        self.analyzer = analyzer
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        if result.isFinal {
                            self.finalized += " " + text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                        self.onText?(self.current)
                    }
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Stops the microphone and returns the final transcript.
    func stop() async -> String {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        analyzer = nil
        results = nil
        return current
    }

    func cancel() async {
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        input?.finish()
        input = nil
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        analyzer = nil
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
    }
}
