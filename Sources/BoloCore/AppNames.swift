import Foundation

/// Spoken app names mapped to the name the app is installed under.
public enum AppNames {
    public static let aliases: [String: String] = [
        "teams": "Microsoft Teams", "ms teams": "Microsoft Teams", "microsoft teams": "Microsoft Teams",
        "outlook": "Microsoft Outlook", "word": "Microsoft Word", "excel": "Microsoft Excel",
        "powerpoint": "Microsoft PowerPoint",
        "chrome": "Google Chrome", "google chrome": "Google Chrome",
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "intellij": "IntelliJ IDEA", "intellij idea": "IntelliJ IDEA", "idea": "IntelliJ IDEA",
        "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings",
        "whatsapp": "WhatsApp", "whats app": "WhatsApp",
        "zoom": "zoom.us", "iterm": "iTerm", "app store": "App Store",
    ]

    /// "teams" -> "Microsoft Teams"; unknown names come back title-cased as spoken.
    public static func canonical(_ spoken: String) -> String {
        let key = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        if let hit = aliases[key] { return hit }
        return key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
