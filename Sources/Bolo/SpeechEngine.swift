@preconcurrency import AVFoundation
import Foundation
import Speech

/// What the speech engine heard: its best guess, its runner-up guesses, and how sure it was.
struct Heard {
    var text: String
    var alternatives: [String] = []
    /// Mean word confidence 0–1, when the engine reports it.
    var confidence: Double?

    /// Best guess first, then distinct alternatives: the parser tries them in this order.
    var candidates: [String] {
        var out = [text]
        for a in alternatives where !out.contains(a) { out.append(a) }
        return out
    }
}

/// What happened on the microphone during one press, for the notch and the logs.
final class MicStats: @unchecked Sendable {
    private let lock = NSLock()
    private var _buffers = 0
    private var _converted = 0
    private var _maxLevel: Float = 0

    func record(level: Float?, converted: Bool) {
        lock.withLock {
            _buffers += 1
            if converted { _converted += 1 }
            if let level { _maxLevel = max(_maxLevel, level) }
        }
    }

    var buffers: Int { lock.withLock { _buffers } }
    /// Buffers that reached the speech engine. 0 while `buffers` grows means conversion is failing.
    var converted: Int { lock.withLock { _converted } }
    var maxLevel: Float { lock.withLock { _maxLevel } }

    func reset() { lock.withLock { _buffers = 0; _converted = 0; _maxLevel = 0 } }
}

/// Streams the microphone into Apple's on-device speech engine while the key is held.
///
/// Hearing setup:
/// - Apple voice processing on the mic (noise suppression, echo cancellation, automatic gain),
///   with other audio ducked as little as possible. If it yields no audio on this Mac's input
///   device, Bolo retries without it on the spot and stays without it for the session.
/// - Apple SpeechTranscriber (measured best on your recordings), with live partial results,
///   alternative transcriptions and word confidence.
/// - The engine stays prepared between presses, and keeps listening briefly after release so the
///   last word isn't clipped.
/// The microphone is on only between `start()` and `stop()`.
@MainActor
final class SpeechEngine {
    enum Kind: String { case dictation, transcriber }

    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Names and words to favour. Used by both engines.
    var contextualStrings: [String] = []
    /// Custom language model for the dictation engine, once built.
    var languageModel: SFSpeechLanguageModel.Configuration?

    private let locale: Locale
    private let kind: Kind
    private var noiseSuppression: Bool
    let stats = MicStats()
    private(set) var micDescription = ""
    private let tail: Duration
    private var audio = AVAudioEngine()
    private var audioConfigured = false
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var segments: [(text: String, alternatives: [String], confidence: Double?)] = []
    private var volatile = ""

    init(settings: Settings) {
        locale = Locale(identifier: settings.speechLocale)
        kind = Kind(rawValue: settings.speechEngine) ?? .dictation
        noiseSuppression = settings.noiseSuppression
        tail = .milliseconds(max(0, settings.releaseTailMs))
    }

    private var current: String {
        (segments.map(\.text).joined(separator: " ") + " " + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum SpeechError: LocalizedError {
        case modelNotReady(String)
        var errorDescription: String? {
            switch self { case .modelNotReady(let why): why }
        }
    }

    private var preparing: Task<Void, Never>?

    /// Makes sure Apple's speech model is on disk, downloading it in the background if not.
    /// Called at launch; a key press never waits for a download.
    func prepare() {
        guard preparing == nil else { return }
        let module = makeModule(resultsTo: nil)
        let locale = self.locale
        preparing = Task {
            if await AssetInventory.status(forModules: [module]) == .installed {
                Log.speech.notice("speech model \(locale.identifier, privacy: .public) installed")
                return
            }
            do {
                try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    Log.speech.notice("downloading speech model \(locale.identifier, privacy: .public)")
                    try await request.downloadAndInstall()
                }
                Log.speech.notice("speech model \(locale.identifier, privacy: .public) ready")
            } catch {
                Log.speech.error("speech model download failed: \(error.localizedDescription, privacy: .public)")
                self.preparing = nil  // try again next time
            }
        }
    }

    /// The configured speech module; `resultsTo` starts collecting its results when given.
    private func makeModule(resultsTo engine: SpeechEngine?) -> any SpeechModule {
        switch kind {
        case .dictation:
            var hints: Set<DictationTranscriber.ContentHint> = [.shortForm]
            if let languageModel { hints.insert(.customizedLanguage(modelConfiguration: languageModel)) }
            let t = DictationTranscriber(
                locale: locale, contentHints: hints, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .alternativeTranscriptions, .frequentFinalization],
                attributeOptions: [.transcriptionConfidence])
            if let engine {
                engine.results = Task { [weak engine] in
                    do {
                        for try await r in t.results { engine?.handle(r.text, r.alternatives, final: r.isFinal) }
                    } catch { Log.speech.error("results: \(error.localizedDescription, privacy: .public)") }
                }
            }
            return t
        case .transcriber:
            let t = SpeechTranscriber(
                locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions],
                attributeOptions: [.transcriptionConfidence])
            if let engine {
                engine.results = Task { [weak engine] in
                    do {
                        for try await r in t.results { engine?.handle(r.text, r.alternatives, final: r.isFinal) }
                    } catch { Log.speech.error("results: \(error.localizedDescription, privacy: .public)") }
                }
            }
            return t
        }
    }

    func start() async throws {
        segments = []
        volatile = ""

        let module = makeModule(resultsTo: self)
        // Never wait for a download on a key press: say so and fetch it in the background.
        if await AssetInventory.status(forModules: [module]) != .installed {
            results?.cancel()
            prepare()
            throw SpeechError.modelNotReady("Apple's speech model for \(locale.identifier) is still downloading. Try again in a minute.")
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation

        // Microphone first, so the first words aren't lost while the analyzer spins up.
        stats.reset()
        do {
            try startMicrophone(into: continuation, format: format)
        } catch {
            // The input device changed (AirPods connected, etc.), or voice processing can't run on it.
            Log.speech.error("mic start failed (\(error.localizedDescription, privacy: .public)); retrying without voice processing")
            try restartMicrophoneWithoutVoiceProcessing(into: continuation, format: format)
        }
        watchForSilentMicrophone(continuation: continuation, format: format)

        let analyzer = SpeechAnalyzer(modules: [module])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(300))
            try? await analyzer.setContext(context)
        }
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)
    }

    /// Voice processing sometimes delivers no audio (or pure zeros) on a given input device. If
    /// nothing real arrives within 0.7 s, switch it off and carry on listening.
    private func watchForSilentMicrophone(continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat?) {
        guard noiseSuppression else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.input != nil, self.noiseSuppression else { return }
            if self.stats.buffers == 0 || self.stats.maxLevel == 0 || self.stats.converted == 0 {
                Log.speech.error("no usable audio with voice processing (\(self.stats.buffers) buffers, \(self.stats.converted) converted); switching it off for this session")
                try? self.restartMicrophoneWithoutVoiceProcessing(into: continuation, format: format)
            }
        }
    }

    private func restartMicrophoneWithoutVoiceProcessing(into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat?) throws {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        noiseSuppression = false
        audio = AVAudioEngine()
        audioConfigured = false
        try startMicrophone(into: continuation, format: format)
    }

    private func startMicrophone(into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat?) throws {
        let node = audio.inputNode
        if !audioConfigured {
            if noiseSuppression {
                do {
                    try node.setVoiceProcessingEnabled(true)
                    node.isVoiceProcessingAGCEnabled = true
                    // Don't turn your music right down while you talk.
                    node.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
                } catch {
                    Log.speech.error("voice processing unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
            audioConfigured = true
        }
        let micFormat = node.outputFormat(forBus: 0)
        micDescription = "\(Int(micFormat.sampleRate)) Hz, \(micFormat.channelCount) ch, voice processing \(noiseSuppression ? "on" : "off")"
        // Voice processing can hand over 7+ channels (processed voice in the first); the converter
        // can't turn 7 into 1, so take the first channel ourselves, then resample.
        // A device mid-switch (AirPods connecting) can report 0 Hz: say so instead of crashing.
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0,
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: micFormat.sampleRate, channels: 1, interleaved: false)
        else {
            throw SpeechError.modelNotReady("The microphone isn't ready (\(Int(micFormat.sampleRate)) Hz). Try again in a second.")
        }
        let converter = format.flatMap { $0 == mono ? nil : AVAudioConverter(from: mono, to: $0) }
        let levelHandler = onLevel
        let stats = self.stats
        node.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in
            let voice = Self.firstChannel(buffer, as: mono)
            let level = voice.flatMap(Self.rms)
            let out = voice.flatMap { Self.resample($0, with: converter, to: format) }
            stats.record(level: level, converted: out != nil)
            if let level { Task { @MainActor in levelHandler?(level) } }
            if let out { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        audio.prepare()
        try audio.start()
    }

    private func handle(_ text: AttributedString, _ alternatives: [AttributedString], final: Bool) {
        let plain = String(text.characters)
        if final {
            segments.append((plain, alternatives.map { String($0.characters) }, Self.confidence(text)))
            volatile = ""
        } else {
            volatile = plain
        }
        onText?(current)
    }

    /// Test without a microphone: feeds a recording through the same channel-and-resample path as the
    /// mic, widened to `channels` (speech in the first, silence in the rest) like voice processing does.
    func transcribe(file url: URL, channels: Int) async throws -> Heard {
        segments = []
        volatile = ""
        let module = makeModule(resultsTo: self)
        // Tests may block on the (per-app) model reservation; key presses never do.
        if await AssetInventory.status(forModules: [module]) != .installed {
            try await AssetInventory.reserve(locale: locale)
            try await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.start(inputSequence: stream)

        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        // More than 2 channels needs an explicit layout (discrete channels, like voice processing's).
        let n = AVAudioChannelCount(max(1, channels))
        let wide = n <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: rate, channels: n)!
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false,
                            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | n)!)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let converter = format.flatMap { $0 == mono ? nil : AVAudioConverter(from: mono, to: $0) }
        let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)!
        stats.reset()
        while file.framePosition < file.length {
            try file.read(into: chunk)
            guard let src = chunk.floatChannelData?[0], let buf = AVAudioPCMBuffer(pcmFormat: wide, frameCapacity: chunk.frameLength) else { break }
            buf.frameLength = chunk.frameLength
            for c in 0..<Int(wide.channelCount) {
                let dst = buf.floatChannelData![c]
                for i in 0..<Int(chunk.frameLength) { dst[i] = c == 0 ? src[i] : 0 }
            }
            let voice = Self.firstChannel(buf, as: mono)
            let out = voice.flatMap { Self.resample($0, with: converter, to: format) }
            stats.record(level: voice.flatMap(Self.rms), converted: out != nil)
            if let out { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await results?.value
        results = nil
        return heard
    }

    /// Stops the microphone and returns what was heard.
    func stop() async -> Heard {
        try? await Task.sleep(for: tail)
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        analyzer = nil
        results = nil
        let h = heard
        Log.speech.notice("mic \(self.micDescription, privacy: .public): \(self.stats.buffers) buffers (\(self.stats.converted) converted), peak level \(String(format: "%.2f", self.stats.maxLevel), privacy: .public); heard \(h.text.count) chars, confidence \(h.confidence.map { String(format: "%.2f", $0) } ?? "n/a", privacy: .public)")
        return h
    }

    func cancel() async {
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        input?.finish()
        input = nil
        await analyzer?.cancelAndFinishNow()
        results?.cancel()
        analyzer = nil
    }

    /// Whole-utterance alternatives: swap one segment at a time for its runner-up guesses.
    private var heard: Heard {
        var alternatives: [String] = []
        for (i, segment) in segments.enumerated() {
            for alt in segment.alternatives.prefix(3) where alt != segment.text {
                var texts = segments.map(\.text)
                texts[i] = alt
                alternatives.append(texts.joined(separator: " ").trimmingCharacters(in: .whitespaces))
            }
        }
        let confidences = segments.compactMap(\.confidence)
        let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        return Heard(text: current, alternatives: Array(alternatives.prefix(6)), confidence: confidence)
    }

    /// Character-weighted mean of the per-word confidence attribute.
    nonisolated private static func confidence(_ text: AttributedString) -> Double? {
        var total = 0.0, weight = 0.0
        for run in text.runs {
            guard let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
            let n = Double(text[run.range].characters.count)
            total += c * n
            weight += n
        }
        return weight > 0 ? total / weight : nil
    }

    /// The first channel as a mono Float32 buffer (the buffer itself when it already is one).
    nonisolated static func firstChannel(_ buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let f = buffer.format
        if f.channelCount == 1, f.commonFormat == .pcmFormatFloat32, !f.isInterleaved { return buffer }
        guard let src = buffer.floatChannelData?[0], buffer.frameLength > 0,
            let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength), let dst = out.floatChannelData?[0]
        else { return nil }
        let stride = f.isInterleaved ? Int(f.channelCount) : 1
        for i in 0..<Int(buffer.frameLength) { dst[i] = src[i * stride] }
        out.frameLength = buffer.frameLength
        return out
    }

    nonisolated static func resample(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let converter, let format else { return buffer }
        return convert(buffer, with: converter, to: format)
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
