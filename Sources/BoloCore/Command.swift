import Foundation

public enum Action: String, Codable, Sendable, CaseIterable {
    case openApp
    case openURL
    case sendMessage      // open the chat, type the text, press send
    case draftMessage     // open the chat and type the text, don't send
    case call
    case newNote
    case addReminder
    case webSearch
    case joinNextMeeting
    case typeText
    case setVolume
    case mute
    case unmute
    case lockScreen
    case runShortcut
}

public enum Channel: String, Codable, Sendable, CaseIterable {
    case whatsapp, teams, imessage, slack, mail

    public var displayName: String {
        switch self {
        case .whatsapp: "WhatsApp"
        case .teams: "Teams"
        case .imessage: "iMessage"
        case .slack: "Slack"
        case .mail: "Mail"
        }
    }

    /// Maps a spoken word to a channel. `nil` means "any messaging app" (use the contact's default).
    public static func from(spoken word: String) -> Channel? {
        switch word.lowercased().replacingOccurrences(of: " ", with: "") {
        case "whatsapp": .whatsapp
        case "teams", "microsoftteams": .teams
        case "imessage": .imessage
        case "slack": .slack
        case "mail", "email": .mail
        default: nil
        }
    }
}

public enum SearchEngine: String, Codable, Sendable {
    case google, youtube
}

public struct Step: Codable, Sendable, Equatable {
    public var action: Action
    public var app: String?
    public var contact: String?
    public var channel: Channel?
    public var text: String?
    public var time: String?
    public var engine: SearchEngine?
    public var number: Int?

    public init(
        _ action: Action, app: String? = nil, contact: String? = nil, channel: Channel? = nil,
        text: String? = nil, time: String? = nil, engine: SearchEngine? = nil, number: Int? = nil
    ) {
        self.action = action
        self.app = app
        self.contact = contact
        self.channel = channel
        self.text = text
        self.time = time
        self.engine = engine
        self.number = number
    }

    /// One line for the notch, e.g. "WhatsApp bhai · I'll be late".
    public var summary: String {
        switch action {
        case .openApp: "Open \(app ?? "app")"
        case .openURL: "Open \(text ?? "link")"
        case .sendMessage: "\(channel?.displayName ?? "Message") \(contact ?? "") · \(text ?? "")"
        case .draftMessage:
            (text ?? "").isEmpty
                ? "Open \(contact ?? "")'s \(channel?.displayName ?? "chat")"
                : "Draft to \(contact ?? "") · \(text ?? "")"
        case .call: "\(channel?.displayName ?? "") call \(contact ?? "")"
        case .newNote: "New note · \(text ?? "")"
        case .addReminder: "Reminder · \(text ?? "")\(time.map { " · \($0)" } ?? "")"
        case .webSearch: "\(engine == .youtube ? "YouTube" : "Google") · \(text ?? "")"
        case .joinNextMeeting: "Join next meeting"
        case .typeText: "Type · \(text ?? "")"
        case .setVolume: "Volume \(number ?? 0)%"
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .lockScreen: "Lock screen"
        case .runShortcut: "Run shortcut \(text ?? "")"
        }
    }
}

public struct Command: Codable, Sendable {
    /// rules = phrase parser, model = Apple's on-device model, qwen = Qwen3.5-4B via MLX.
    public enum Source: String, Codable, Sendable { case rules, model, qwen }

    public var utterance: String
    public var steps: [Step]
    public var source: Source

    public init(utterance: String, steps: [Step], source: Source) {
        self.utterance = utterance
        self.steps = steps
        self.source = source
    }
}
