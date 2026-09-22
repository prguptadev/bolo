import AVFoundation
import Foundation
import Speech
import WhisperKit

// speech-eval apple   <dir of .wav, or one .wav> [--locale en_IN]
// speech-eval whisper <dir of .wav, or one .wav> [--lang en|hi|auto] [--model large-v3-v20240930_626MB]
// Prints one JSON line per file: {"id","text","ms"}. First line is {"id":"_load","ms":…} (model load time).

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

func emit(_ id: String, _ text: String?, _ ms: Double) {
    var row: [String: Any] = ["id": id, "ms": Int(ms)]
    if let text { row["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}

func appleTranscribe(_ url: URL, locale: Locale) async throws -> String {
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await install.downloadAndInstall()
    }
    let collect = Task { () -> String in
        var text = ""
        for try await r in transcriber.results where r.isFinal { text += String(r.text.characters) }
        return text
    }
    let file = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collect.value
}

Task {
    do {
        switch engine {
        case "apple":
            let locale = Locale(identifier: option("--locale", "en_IN"))
            emit("_load", nil, 0)
            for f in files {
                let t = Date()
                let text = try await appleTranscribe(f, locale: locale)
                emit(f.deletingPathExtension().lastPathComponent, text, Date().timeIntervalSince(t) * 1000)
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
