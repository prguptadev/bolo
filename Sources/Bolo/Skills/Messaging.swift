import AppKit
import BoloCore
import Foundation

/// Sends and drafts messages. Chat apps without scripting (WhatsApp, Teams) are opened with a
/// deep link that pre-fills the text; Bolo then checks the text box holds exactly that text
/// before pressing Return, so a slow-loading chat never gets a wrong or empty send.
struct Messaging {
    let settings: Settings
    let isCancelled: () -> Bool

    func send(_ step: Step, to person: Person, channel: Channel, send: Bool) async throws -> String {
        let text = step.text ?? ""
        switch channel {
        case .whatsapp:
            guard let phone = person.phone else { throw SkillError.failed("No phone number for \(person.displayName).") }
            let digits = normalizedPhone(phone)
            let url = "whatsapp://send?phone=\(digits)&text=\(encode(text))"
            return try await deepLinkChat(
                url: url, bundleID: "net.whatsapp.WhatsApp", app: "WhatsApp", person: person, text: text, send: send)

        case .teams:
            guard let email = person.email else { throw SkillError.failed("No Teams email for \(person.displayName). Add it in Nicknames.") }
            var url = "msteams:/l/chat/0/0?users=\(encode(email))"
            if !text.isEmpty { url += "&message=\(encode(text))" }
            return try await deepLinkChat(
                url: url, bundleID: "com.microsoft.teams2", app: "Teams", person: person, text: text, send: send)

        case .imessage:
            guard let handle = person.phone ?? person.email else { throw SkillError.failed("No phone or email for \(person.displayName).") }
            if send, !text.isEmpty {
                try await MacControl.appleScript("""
                    tell application "Messages"
                        set svc to 1st account whose service type = iMessage
                        send \(MacControl.quoted(text)) to participant \(MacControl.quoted(handle)) of svc
                    end tell
                    """)
                return "Sent to \(person.displayName) on iMessage"
            }
            if let url = URL(string: "imessage://\(encode(handle))") { NSWorkspace.shared.open(url) }
            if !text.isEmpty {
                try await Task.sleep(for: .seconds(1.2))
                await MacControl.paste(text)
            }
            return "Opened \(person.displayName)'s iMessage chat"

        case .mail:
            guard let email = person.email else { throw SkillError.failed("No email address for \(person.displayName).") }
            let subject = text.split(separator: " ").prefix(6).joined(separator: " ")
            try await MacControl.appleScript("""
                tell application "Mail"
                    set m to make new outgoing message with properties {subject:\(MacControl.quoted(subject)), content:\(MacControl.quoted(text)), visible:\(send ? "false" : "true")}
                    tell m to make new to recipient at end of to recipients with properties {address:\(MacControl.quoted(email))}
                    \(send ? "send m" : "activate")
                end tell
                """)
            return send ? "Mailed \(person.displayName)" : "Mail draft to \(person.displayName) is open"

        case .slack:
            return try await sendByName(person.displayName, channel: .slack, text: text, send: send)
        }
    }

    // MARK: - Chats found by name (groups, people without a saved number, Slack)

    private static let chatApps: [Channel: (bundle: String, name: String, searchKey: String)] = [
        .whatsapp: ("net.whatsapp.WhatsApp", "WhatsApp", "cmd+f"),
        .teams: ("com.microsoft.teams2", "Teams", "cmd+e"),
        .slack: ("com.tinyspeck.slackmacgap", "Slack", "cmd+k"),
    ]

    /// Opens the chat by searching the app for exactly `name`, types the text, and sends only if the
    /// text box can be read back and holds exactly the message (stricter than the deep-link path).
    func sendByName(_ name: String, channel: Channel, text: String, send: Bool) async throws -> String {
        guard let app = Self.chatApps[channel] else { throw SkillError.failed("Can't search chats in \(channel.displayName).") }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundle) else {
            throw SkillError.failed("\(app.name) isn't installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let running = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        guard try await waitUntil(seconds: 8, { MacControl.frontmostBundleID() == app.bundle }) else {
            throw SkillError.failed("\(app.name) didn't come to the front.")
        }
        try await Task.sleep(for: .milliseconds(400))
        let pid = running.processIdentifier
        let opened = try await ScreenControl.openChat(named: name, pid: pid, appName: app.name, searchKey: app.searchKey)
        guard !text.isEmpty else { return opened }

        await MacControl.paste(text)
        let matched = try await waitUntil(seconds: 3) {
            guard let value = MacControl.focusedText(pid: pid) else { return false }
            return Self.same(value, text)
        }
        Log.skills.notice("\(app.name, privacy: .public) by-name compose matched=\(matched)")
        if !send { return opened + " · draft typed" }
        guard matched else {
            throw SkillError.failed("Opened \(name) in \(app.name) but couldn't confirm the message box, so I didn't send.")
        }
        try await Task.sleep(for: .seconds(settings.sendDelaySeconds))
        if isCancelled() { return "Cancelled. The draft is in \(app.name)." }
        guard MacControl.frontmostBundleID() == app.bundle else {
            throw SkillError.failed("\(app.name) lost focus, so I didn't send. The draft is still there.")
        }
        MacControl.press(.returnKey)
        return "Sent to \(name) on \(app.name)"
    }

    func call(_ person: Person, channel: Channel) async throws -> String {
        guard channel == .teams else { throw SkillError.failed("Calls work on Teams for now.") }
        guard let email = person.email else { throw SkillError.failed("No Teams email for \(person.displayName).") }
        guard let url = URL(string: "msteams:/l/call/0/0?users=\(encode(email))") else { throw SkillError.failed("Bad Teams address for \(person.displayName).") }
        NSWorkspace.shared.open(url)
        return "Calling \(person.displayName) on Teams"
    }

    // MARK: - Deep-link chats

    private func deepLinkChat(url: String, bundleID: String, app: String, person: Person, text: String, send: Bool) async throws -> String {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            throw SkillError.failed("\(app) isn't installed.")
        }
        guard let link = URL(string: url), NSWorkspace.shared.open(link) else {
            throw SkillError.failed("Couldn't open \(app).")
        }
        guard !text.isEmpty else { return "Opened \(person.displayName)'s \(app) chat" }

        // Wait for the app to come to the front with the chat loaded.
        guard try await waitUntil(seconds: 8, { MacControl.frontmostBundleID() == bundleID }) else {
            throw SkillError.failed("\(app) didn't come to the front. The draft may still be there.")
        }
        guard let pid = MacControl.running(bundleID)?.processIdentifier else { throw SkillError.failed("\(app) isn't running.") }

        // nil = the app doesn't expose its text box; then fall back to a fixed settle time.
        var readable = MacControl.focusedText(pid: pid) != nil
        let matched = try await waitUntil(seconds: 6) {
            guard let value = MacControl.focusedText(pid: pid) else { return false }
            readable = true
            return Self.same(value, text)
        }
        // The focused element isn't always the message box: look for the text anywhere in the window.
        let inWindow = matched || ScreenControl.windowTextFields(pid: pid).contains { Self.same($0, text) }
        Log.skills.notice("\(app, privacy: .public) text box readable=\(readable) matched=\(matched) inWindow=\(inWindow)")
        if !send { return inWindow ? "Draft ready in \(app) for \(person.displayName)" : "Opened \(person.displayName)'s \(app) chat" }
        // Never press Return without seeing the exact message: a wrong autonomous send is the worst failure.
        guard inWindow else {
            throw SkillError.failed("Typed the message for \(person.displayName) but couldn't confirm it in \(app), so I didn't send. It's a draft.")
        }

        try await Task.sleep(for: .seconds(settings.sendDelaySeconds))
        if isCancelled() { return "Cancelled. The draft is still in \(app)." }
        guard MacControl.frontmostBundleID() == bundleID else {
            throw SkillError.failed("\(app) lost focus, so I didn't send. The draft is still there.")
        }
        MacControl.press(.returnKey)

        if readable {
            let cleared = try await waitUntil(seconds: 3) { (MacControl.focusedText(pid: pid) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !cleared { throw SkillError.failed("Pressed send in \(app), but the text is still in the box. Check the chat.") }
        }
        _ = readable
        return "Sent to \(person.displayName) on \(app)"
    }

    func waitUntil(seconds: Double, _ condition: @escaping () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isCancelled() { return false }
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(150))
        }
        return condition()
    }

    static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return norm(a) == norm(b)
    }

    private func normalizedPhone(_ phone: String) -> String {
        var digits = phone.filter(\.isNumber)
        if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return digits }
        if digits.hasPrefix("0") { digits.removeFirst() }
        return digits.count == 10 ? settings.defaultCountryCode + digits : digits
    }

    private func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
