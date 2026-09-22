import AppKit
import BoloCore
import EventKit
import Foundation

/// Apps, links, notes, reminders, meetings and system controls.
enum Everyday {
    // MARK: Apps

    private static let appFolders = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications", "/System/Library/CoreServices",
    ]

    /// Installed app names, lowercased, mapped to their bundle URL.
    static func installedApps() -> [String: URL] {
        var apps: [String: URL] = [:]
        let fm = FileManager.default
        for folder in appFolders {
            guard let items = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for item in items {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    apps[String(item.dropLast(4)).lowercased()] = url
                } else if let inner = try? fm.contentsOfDirectory(atPath: url.path) {
                    // One level down, e.g. /Applications/Microsoft Office/*.app
                    for sub in inner where sub.hasSuffix(".app") {
                        apps[String(sub.dropLast(4)).lowercased()] = url.appendingPathComponent(sub)
                    }
                }
            }
        }
        return apps
    }

    static func openApp(_ name: String, installed: [String: URL]) async throws -> String {
        let key = name.lowercased()
        let url = installed[key]
            ?? installed.first { $0.key.hasPrefix(key) }?.value
            ?? installed.first { $0.key.contains(key) }?.value
        guard let url else { throw SkillError.failed("Couldn't find an app called \(name).") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return "Opened \(url.deletingPathExtension().lastPathComponent)"
    }

    // MARK: Web

    static func openURL(_ text: String) throws -> String {
        let s = text.lowercased().hasPrefix("http") ? text : "https://" + text
        guard let url = URL(string: s), NSWorkspace.shared.open(url) else { throw SkillError.failed("Couldn't open \(text).") }
        return "Opened \(text)"
    }

    static func search(_ query: String, engine: SearchEngine) throws -> String {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = engine == .youtube
            ? "https://www.youtube.com/results?search_query=\(q)" : "https://www.google.com/search?q=\(q)"
        guard let link = URL(string: url) else { throw SkillError.failed("Couldn't search for \(query).") }
        NSWorkspace.shared.open(link)
        return "Searched \(engine == .youtube ? "YouTube" : "Google") for \(query)"
    }

    // MARK: Notes

    static func newNote(_ text: String) async throws -> String {
        let html = text
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        try await MacControl.appleScript("""
            tell application "Notes"
                try
                    make new note at folder "Notes" of default account with properties {body:\(MacControl.quoted("<div>" + html + "</div>"))}
                on error
                    make new note at (first folder of default account) with properties {body:\(MacControl.quoted("<div>" + html + "</div>"))}
                end try
            end tell
            """)
        return "Added a note"
    }

    // MARK: Reminders and meetings

    private static let store = EKEventStore()

    static func addReminder(_ text: String, time: String?) async throws -> String {
        guard try await store.requestFullAccessToReminders() else {
            throw SkillError.failed("Bolo needs Reminders access (System Settings › Privacy › Reminders).")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = store.defaultCalendarForNewReminders()
        var when = ""
        if let time, let date = TimePhrase.resolve(time) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
            when = " for " + date.formatted(date: .omitted, time: .shortened)
        }
        try store.save(reminder, commit: true)
        return "Reminder set\(when)"
    }

    private static let meetingLink = try! NSRegularExpression(
        pattern: "https://(?:teams\\.microsoft\\.com/l/meetup-join/|teams\\.live\\.com/meet/|[\\w.-]*zoom\\.us/j/|meet\\.google\\.com/)[^\\s\"<>]+")

    static func joinNextMeeting() async throws -> String {
        guard try await store.requestFullAccessToEvents() else {
            throw SkillError.failed("Bolo needs Calendar access (System Settings › Privacy › Calendars).")
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-30 * 60), end: now.addingTimeInterval(3 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        for event in events {
            let haystack = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
            if let m = meetingLink.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)),
                let r = Range(m.range, in: haystack), let url = URL(string: String(haystack[r]))
            {
                NSWorkspace.shared.open(url)
                return "Joining \(event.title ?? "meeting")"
            }
        }
        throw SkillError.failed("No meeting with a join link in the next 3 hours.")
    }

    // MARK: System

    static func setVolume(_ percent: Int) async throws -> String {
        try await MacControl.appleScript("set volume output volume \(max(0, min(100, percent)))")
        return "Volume \(percent)%"
    }

    static func mute(_ on: Bool) async throws -> String {
        try await MacControl.appleScript(on ? "set volume with output muted" : "set volume without output muted")
        return on ? "Muted" : "Unmuted"
    }

    static func lockScreen() -> String {
        MacControl.press(.q, flags: [.maskCommand, .maskControl])
        return "Locked"
    }

    static func runShortcut(_ name: String) async throws -> String {
        try await MacControl.run("/usr/bin/shortcuts", ["run", name])
        return "Ran \(name)"
    }
}
