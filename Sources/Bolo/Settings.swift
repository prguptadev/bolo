import Foundation

/// Files live in ~/Library/Application Support/Bolo and are plain JSON, edited from the menu bar.
struct Settings: Codable {
    /// Pause between the draft appearing and Bolo pressing send. Esc during it cancels.
    var sendDelaySeconds: Double = 0.8
    /// Added to 10-digit phone numbers that have no country code.
    var defaultCountryCode: String = "91"
    /// Speech recognition locale. English (India) is installed on-device by macOS.
    var speechLocale: String = "en_IN"
    /// "dictation": Apple's dictation model in short-command mode, with Bolo's custom vocabulary and
    /// alternative guesses. "transcriber": Apple's newer general transcription model.
    var speechEngine: String = "transcriber"
    /// Apple voice processing on the microphone: noise suppression, echo cancellation, automatic gain.
    var noiseSuppression: Bool = true
    /// Teach the dictation model your contact names, app names and Bolo's command phrases.
    var customVocabulary: Bool = false
    /// Keep listening this long after the key is released, so the last word isn't cut off.
    var releaseTailMs: Int = 350
    /// Below this speech confidence (0–1), messages are typed as drafts instead of sent.
    var minSendConfidence: Double = 0.6
    /// Use a model when the phrase patterns don't match.
    var useModelFallback: Bool = true
    /// "qwen": Qwen3.5-4B on the GPU (best; needs the 3.1 GB download, see `Bolo --download-brain`).
    /// "apple": Apple's on-device model (built in, weaker; it may not send, call or type).
    var brain: String = "qwen"
    /// Unload Qwen after this many seconds without use, freeing ~3.2 GB.
    var brainIdleSeconds: Double = 300
    /// Bumped when a default changes because of measurements, so old defaults get upgraded.
    var settingsVersion: Int = 2

    init() {}

    /// Missing keys take their defaults, so older settings files keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        sendDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .sendDelaySeconds) ?? d.sendDelaySeconds
        defaultCountryCode = try c.decodeIfPresent(String.self, forKey: .defaultCountryCode) ?? d.defaultCountryCode
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? d.speechLocale
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? d.speechEngine
        noiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .noiseSuppression) ?? d.noiseSuppression
        customVocabulary = try c.decodeIfPresent(Bool.self, forKey: .customVocabulary) ?? d.customVocabulary
        releaseTailMs = try c.decodeIfPresent(Int.self, forKey: .releaseTailMs) ?? d.releaseTailMs
        minSendConfidence = try c.decodeIfPresent(Double.self, forKey: .minSendConfidence) ?? d.minSendConfidence
        useModelFallback = try c.decodeIfPresent(Bool.self, forKey: .useModelFallback) ?? d.useModelFallback
        brain = try c.decodeIfPresent(String.self, forKey: .brain) ?? d.brain
        brainIdleSeconds = try c.decodeIfPresent(Double.self, forKey: .brainIdleSeconds) ?? d.brainIdleSeconds
        settingsVersion = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        if settingsVersion < 2 {
            // v2 (speech eval on 50 recordings, 2026-09-22): the transcriber beat dictation, the custom
            // vocabulary didn't help, and garbled Hinglish scored 0.45–0.49. Upgrade untouched old defaults.
            if speechEngine == "dictation" { speechEngine = d.speechEngine }
            if customVocabulary { customVocabulary = d.customVocabulary }
            if minSendConfidence == 0.45 { minSendConfidence = d.minSendConfidence }
            settingsVersion = 2
        }
    }

    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bolo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let settingsURL = folder.appendingPathComponent("settings.json")
    static let nicknamesURL = folder.appendingPathComponent("nicknames.json")
    static let historyURL = folder.appendingPathComponent("history.jsonl")

    /// Reads the settings file, then writes it back with every key present so new options show up
    /// for editing. Your existing values are kept.
    static func load() -> Settings {
        var s = Settings()
        if let data = try? Data(contentsOf: settingsURL) {
            guard let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
                return s  // unreadable (e.g. a typo): use defaults, don't overwrite the user's file
            }
            s = decoded
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(s).write(to: settingsURL)
        return s
    }
}

/// A nickname you say ("bhai", "mom") mapped to how to reach that person.
/// Contacts' own Nickname field works too; this file is for anything not in Contacts.
struct Nickname: Codable {
    var name: String?
    var phone: String?
    var email: String?
    /// whatsapp, teams, imessage, mail. Used when you don't name an app.
    var channel: String?
}

enum Nicknames {
    static func load() -> [String: Nickname] {
        if !FileManager.default.fileExists(atPath: Settings.nicknamesURL.path) {
            let example = """
                {
                  "_example_bhai": {
                    "name": "Rahul",
                    "phone": "+91 XXXXX XXXXX",
                    "email": "rahul@company.com",
                    "channel": "whatsapp"
                  }
                }
                """
            try? example.write(to: Settings.nicknamesURL, atomically: true, encoding: .utf8)
        }
        guard let data = try? Data(contentsOf: Settings.nicknamesURL),
            let all = try? JSONDecoder().decode([String: Nickname].self, from: data)
        else { return [:] }
        return all.filter { !$0.key.hasPrefix("_") }.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    }
}
