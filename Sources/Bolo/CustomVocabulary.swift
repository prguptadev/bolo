import CryptoKit
import Foundation
import Speech

/// Builds an on-device custom language model for Apple's dictation engine: your contact names and
/// nicknames, installed app names, and Bolo's command phrases in English and Hinglish. It makes
/// "bhai ko WhatsApp karo" and "IntelliJ kholo" likely instead of "by co what's up Carol".
///
/// Rebuilt only when names or apps change (the file name carries a hash of its inputs).
enum CustomVocabulary {
    /// Bump when the templates below change.
    private static let templatesVersion = "1"

    private static let templates: [(String, Int)] = [
        ("<contact> ko <channel> karo", 300), ("<contact> ko <channel> pe message karo", 200),
        ("<contact> ko message bhejo", 200), ("<contact> ko message karo", 150), ("<contact> ko bol do", 150),
        ("<contact> ko bolo", 100), ("<contact> ko <channel> pe likho", 100), ("<contact> ko call karo", 100),
        ("<contact> ko teams pe call karo", 60),
        ("send a <channel> message to <contact> saying", 200), ("message <contact> on <channel>", 150),
        ("tell <contact> on <channel> that", 100), ("text <contact>", 100), ("<channel> <contact>", 100),
        ("open <contact>'s <channel> chat", 100), ("open <channel> chat with <contact>", 80),
        ("teams call <contact>", 100), ("call <contact> on teams", 80),
        ("open <app>", 300), ("<app> kholo", 200), ("launch <app>", 60), ("switch to <app>", 60),
    ]

    private static let phrases: [(String, Int)] = [
        ("new note", 200), ("note down", 100), ("remind me at", 200), ("remind me in", 150), ("remind me to", 150),
        ("yaad dilana", 100), ("mujhe yaad dilana", 80), ("search youtube for", 150), ("search google for", 100),
        ("google karo", 80), ("youtube pe search karo", 60), ("join my next meeting", 150), ("next meeting join karo", 60),
        ("volume", 60), ("mute", 60), ("unmute", 40), ("lock the screen", 60), ("run my shortcut", 40),
        ("type", 40), ("aur", 80), ("and then", 60), ("saying", 100), ("bhejo", 100), ("karo", 150), ("kholo", 150),
        ("likho", 80), ("bol do", 80),
    ]

    static func prepare(locale: Locale, names: [String], apps: [String]) async -> SFSpeechLanguageModel.Configuration? {
        let names = Array(Set(names.map { $0.lowercased() }.filter { $0.count > 1 })).sorted()
        let apps = Array(Set(apps)).sorted()
        let inputs = ([locale.identifier, templatesVersion] + names + apps).joined(separator: "|")
        let version = SHA256.hash(data: Data(inputs.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()

        let dir = Settings.folder.appendingPathComponent("vocabulary", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = SFSpeechLanguageModel.Configuration(
            languageModel: dir.appendingPathComponent("lm-\(version).bin"),
            vocabulary: dir.appendingPathComponent("vocab-\(version).bin"))
        if FileManager.default.fileExists(atPath: config.languageModel.path) { return config }

        let started = Date()
        do {
            let data = SFCustomLanguageModelData(locale: locale, identifier: "dev.prgupta.bolo", version: version)
            let generator = SFCustomLanguageModelData.TemplatePhraseCountGenerator()
            generator.define(className: "contact", values: names.isEmpty ? ["bhai", "mom", "papa"] : names)
            generator.define(className: "channel", values: ["WhatsApp", "Teams", "iMessage"])
            generator.define(className: "app", values: apps)
            for (template, count) in templates { generator.insert(template: template, count: count) }
            data.insert(phraseCountGenerator: generator)
            for (phrase, count) in phrases { data.insert(phraseCount: .init(phrase: phrase, count: count)) }

            let asset = dir.appendingPathComponent("data-\(version).bin")
            try await data.export(to: asset)
            try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: asset, configuration: config)
            // Old builds are no longer needed.
            for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where !old.lastPathComponent.contains(version) {
                try? FileManager.default.removeItem(at: old)
            }
            Log.speech.notice("custom vocabulary ready: \(names.count) names, \(apps.count) apps, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return config
        } catch {
            Log.speech.error("custom vocabulary failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
