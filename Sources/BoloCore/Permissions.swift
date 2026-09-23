import Foundation

/// How much a step can change. The agent loop and one-shot commands both check this against the
/// permission level you chose in settings.
public enum Risk: Int, Comparable, Sendable {
    case read = 0          // look, answer, calculate, search
    case navigate = 1      // open apps, links, folders, click around, scroll, keys
    case write = 2         // type text, make notes, drafts, reminders, menus that edit
    case send = 3          // messages and calls that leave the Mac (after checks)
    case system = 4        // sleep, restart, Wi-Fi, quit apps
    case destructive = 5   // empty the Bin, shut down, delete

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        ["read", "navigate", "write", "send", "system", "destructive"][rawValue]
    }
}

public enum PermissionLevel: String, Codable, Sendable, CaseIterable {
    /// Read, open, navigate and type. Nothing leaves the Mac; nothing is deleted.
    case safe
    /// Plus sending (after the text is confirmed) and system actions, with a countdown for irreversible ones.
    case standard
    /// Plus destructive actions without extra limits.
    case full

    public func allows(_ risk: Risk) -> Bool {
        switch self {
        case .safe: risk <= .write
        case .standard: risk <= .destructive
        case .full: true
        }
    }
}

extension Step {
    public var risk: Risk {
        switch action {
        case .answer, .lookup, .calculate: .read
        case .openApp, .openURL, .webSearch, .click, .menu, .scroll, .pressKey, .goBack, .joinNextMeeting: .navigate
        case .typeText, .typeInto, .newNote, .addReminder, .draftMessage, .runShortcut: .write
        case .sendMessage, .call: .send
        case .setVolume, .mute, .unmute, .lockScreen: .navigate
        case .system:
            switch SystemOp(rawValue: target ?? "") {
            case .emptyTrash?, .shutdown?, .logout?: .destructive
            case .restart?, .sleep?, .wifiOff?, .wifiOn?, .quitApp?: .system
            case .battery?, .diskSpace?, .ipAddress?, .time?, .date?, .clipboard?: .read
            default: .navigate
            }
        }
    }
}
