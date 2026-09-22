import AVFoundation
import Foundation
import Speech
import WhisperKit

// speech-eval apple     <dir of .wav, or one .wav> [--locale en_IN]
// speech-eval dictation <dir|wav> [--locale en_IN|hi_IN] [--lm lm.bin --vocab vocab.bin]   (short-form mode)
// speech-eval whisper   <dir|wav> [--lang en|hi|auto] [--model large-v3-v20240930_626MB]
// Prints one JSON line per file: {"id","text","alts","conf","ms"}. First line is {"id":"_load","ms":…}.
// Hindi (hi_IN) output is transliterated to Latin letters so Bolo's parser can read it.

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: speech-eval apple|whisper <dir> [--locale en_IN] [--lang en|hi|auto] [--model NAME]")
    exit(2)
}
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    return args[i + 1]
}

let engine = args[1]
let input = URL(fileURLWithPath: args[2])
let files = (input.pathExtension == "wav" ? [input] : ((try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? []))
    .filter { $0.pathExtension == "wav" }
    .filter { ((try? AVAudioFile(forReading: $0).length) ?? 0) > 1600 }  // skip empty/<0.1 s files (the analyzer never finishes on them)
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

func emit(_ id: String, _ text: String?, _ ms: Double, alts: [String] = [], conf: Double? = nil) {
    var row: [String: Any] = ["id": id, "ms": Int(ms)]
    if let text { row["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    if !alts.isEmpty { row["alts"] = alts }
    if let conf { row["conf"] = (conf * 100).rounded() / 100 }
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}

struct Heard {
    var text = ""
    var alts: [String] = []
    var conf: Double?
    var segments: [(String, [String])] = []

    /// Whole-utterance alternatives: swap one segment at a time (same as Bolo's SpeechEngine).
    mutating func finish() {
        var out: [String] = []
        for (i, seg) in segments.enumerated() {
            for alt in seg.1.prefix(3) where alt != seg.0 {
                var texts = segments.map(\.0)
                texts[i] = alt
                out.append(texts.joined().trimmingCharacters(in: .whitespaces))
            }
        }
        alts = Array(out.prefix(6))
    }
}

func confidence(_ t: AttributedString) -> Double? {
    var total = 0.0, weight = 0.0
    for run in t.runs {
        guard let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else { continue }
        let n = Double(t[run.range].characters.count)
        total += c * n
        weight += n
    }
    return weight > 0 ? total / weight : nil
}

func latin(_ s: String, _ locale: Locale) -> String {
    guard locale.identifier.hasPrefix("hi") else { return s }
    return s.applyingTransform(StringTransform(rawValue: "Devanagari-Latin; Latin-ASCII"), reverse: false) ?? s
}

func run(_ module: any SpeechModule, _ url: URL, collect: Task<Heard, Error>) async throws -> Heard {
    if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await install.downloadAndInstall()
    }
    let file = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [module])
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collect.value
}

func appleTranscribe(_ url: URL, locale: Locale) async throws -> Heard {
    let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions], attributeOptions: [.transcriptionConfidence])
    let collect = Task { () -> Heard in
        var h = Heard(); var confs: [Double] = []
        for try await r in t.results where r.isFinal {
            h.text += String(r.text.characters)
            h.segments.append((String(r.text.characters), r.alternatives.map { String($0.characters) }))
            if let c = confidence(r.text) { confs.append(c) }
        }
        h.conf = confs.isEmpty ? nil : confs.reduce(0, +) / Double(confs.count)
        h.finish()
        return h
    }
    return try await run(t, url, collect: collect)
}

func dictationTranscribe(_ url: URL, locale: Locale, lm: SFSpeechLanguageModel.Configuration?) async throws -> Heard {
    var hints: Set<DictationTranscriber.ContentHint> = [.shortForm]
    if let lm { hints.insert(.customizedLanguage(modelConfiguration: lm)) }
    let t = DictationTranscriber(locale: locale, contentHints: hints, transcriptionOptions: [], reportingOptions: [.alternativeTranscriptions], attributeOptions: [.transcriptionConfidence])
    let collect = Task { () -> Heard in
        var h = Heard(); var confs: [Double] = []
        for try await r in t.results where r.isFinal {
            h.text += latin(String(r.text.characters), locale)
            h.segments.append((latin(String(r.text.characters), locale), r.alternatives.map { latin(String($0.characters), locale) }))
            if let c = confidence(r.text) { confs.append(c) }
        }
        h.conf = confs.isEmpty ? nil : confs.reduce(0, +) / Double(confs.count)
        h.finish()
        return h
    }
    return try await run(t, url, collect: collect)
}

Task {
    do {
        switch engine {
        case "apple":
            let locale = Locale(identifier: option("--locale", "en_IN"))
            emit("_load", nil, 0)
            for f in files {
                let t = Date()
                let h = try await appleTranscribe(f, locale: locale)
                emit(f.deletingPathExtension().lastPathComponent, h.text, Date().timeIntervalSince(t) * 1000, alts: h.alts, conf: h.conf)
            }
        case "dictation":
            let locale = Locale(identifier: option("--locale", "en_IN"))
            let lmPath = option("--lm", "")
            let lm = lmPath.isEmpty ? nil : SFSpeechLanguageModel.Configuration(
                languageModel: URL(fileURLWithPath: lmPath), vocabulary: URL(fileURLWithPath: option("--vocab", "")))
            emit("_load", nil, 0)
            for f in files {
                let t = Date()
                let h = try await dictationTranscribe(f, locale: locale, lm: lm)
                emit(f.deletingPathExtension().lastPathComponent, h.text, Date().timeIntervalSince(t) * 1000, alts: h.alts, conf: h.conf)
            }
        case "whisper":
            let lang = option("--lang", "en")
            let t0 = Date()
            let pipe = try await WhisperKit(WhisperKitConfig(model: option("--model", "large-v3-v20240930_626MB")))
            emit("_load", nil, Date().timeIntervalSince(t0) * 1000)
            let options = DecodingOptions(
                task: .transcribe, language: lang == "auto" ? nil : lang, temperature: 0,
                usePrefillPrompt: lang != "auto", detectLanguage: lang == "auto")
            for f in files {
                let t = Date()
                let results = try await pipe.transcribe(audioPath: f.path, decodeOptions: options)
                emit(f.deletingPathExtension().lastPathComponent, results.map(\.text).joined(separator: " "), Date().timeIntervalSince(t) * 1000)
            }
        default:
            print("unknown engine \(engine)")
            exit(2)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
RunLoop.main.run()
