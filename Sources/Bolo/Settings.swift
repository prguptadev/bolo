import Foundation

/// Files live in ~/Library/Application Support/Bolo and are plain JSON, edited from the menu bar.
struct Settings: Codable {
    /// Pause between the draft appearing and Bolo pressing send. Esc during it cancels.
    var sendDelaySeconds: Double = 0.8
    /// Added to 10-digit phone numbers that have no country code.
    var defaultCountryCode: String = "91"
    /// Speech recognition locale. English (India) is installed on-device by macOS.
    var speechLocale: String = "en_IN"
    /// Use Apple's on-device model when the phrase patterns don't match.
    var useModelFallback: Bool = true

    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bolo", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let settingsURL = folder.appendingPathComponent("settings.json")
    static let nicknamesURL = folder.appendingPathComponent("nicknames.json")
    static let historyURL = folder.appendingPathComponent("history.jsonl")

    static func load() -> Settings {
        if let data = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(Settings.self, from: data) {
            return s
        }
        let s = Settings()
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
                    "phone": "+91 98765 43210",
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
