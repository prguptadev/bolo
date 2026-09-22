import BoloCore
import Foundation

/// Runs one step with the right skill and returns a short line for the notch.
final class Executor {
    let settings: Settings
    let contacts: ContactBook
    var installedApps: [String: URL]
    var isCancelled: () -> Bool = { false }
    /// The app you were in when you started talking.
    var frontAtStart: String?

    private static let chatApps: Set<String> = [
        "net.whatsapp.WhatsApp", "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
        "com.apple.mail", "com.microsoft.Outlook",
    ]

    init(settings: Settings, contacts: ContactBook) {
        self.settings = settings
        self.contacts = contacts
        self.installedApps = Everyday.installedApps()
    }

    func run(_ step: Step) async throws -> String {
        // Never type or press anything into the lock screen (it's the "front app" while locked).
        if MacControl.frontmostBundleID() == "com.apple.loginwindow" {
            throw SkillError.failed("The Mac is locked. Unlock it first.")
        }
        let messaging = Messaging(settings: settings, isCancelled: isCancelled)
        switch step.action {
        case .sendMessage, .draftMessage:
            var send = step.action == .sendMessage
            let text = step.text ?? ""
            do {
                let person = try contacts.resolve(step.contact ?? "")
                // "Vasu" heard, "Vashu" in Contacts: probably right, but only a draft until you check.
                if person.matchedBySpelling, send {
                    send = false
                    Log.agent.notice("\(step.contact ?? "", privacy: .public) matched \(person.displayName, privacy: .public) by spelling: draft, not send")
                }
                let channel = step.channel ?? person.channel ?? .whatsapp
                // No number/email for this app (or it's Slack): find the chat by name inside the app.
                if (channel == .whatsapp && person.phone == nil) || (channel == .teams && person.email == nil) || channel == .slack {
                    return try await messaging.sendByName(person.displayName, channel: channel, text: text, send: send)
                }
                return try await messaging.send(step, to: person, channel: channel, send: send)
            } catch ResolveError.unknown(let who) {
                // Not a contact, but you named the app ("open the family group on WhatsApp"): search its chats.
                guard let channel = step.channel, [.whatsapp, .teams, .slack].contains(channel) else { throw ResolveError.unknown(who) }
                return try await messaging.sendByName(who, channel: channel, text: text, send: send)
            }
        case .call:
            let person = try contacts.resolve(step.contact ?? "")
            return try await messaging.call(person, channel: step.channel ?? .teams)
        case .openApp:
            return try await Everyday.openApp(step.app ?? "", installed: installedApps)
        case .openURL:
            return try Everyday.openURL(step.text ?? "")
        case .webSearch:
            return try Everyday.search(step.text ?? "", engine: step.engine ?? .google)
        case .newNote:
            return try await Everyday.newNote(step.text ?? "")
        case .addReminder:
            return try await Everyday.addReminder(step.text ?? "", time: step.time)
        case .joinNextMeeting:
            return try await Everyday.joinNextMeeting()
        case .typeText:
            // Typing into a chat app goes to whichever conversation is open. Only do that when you were
            // already looking at it, not in an app Bolo just brought up.
            if let front = MacControl.frontmostBundleID(), Self.chatApps.contains(front), front != frontAtStart {
                throw SkillError.failed("I won't type into whichever chat is open. Say who it's for, like \"message Prashant on WhatsApp bye-bye\".")
            }
            await MacControl.paste(step.text ?? "")
            return "Typed it"
        case .setVolume:
            return try await Everyday.setVolume(step.number ?? 50)
        case .mute:
            return try await Everyday.mute(true)
        case .unmute:
            return try await Everyday.mute(false)
        case .lockScreen:
            return Everyday.lockScreen()
        case .runShortcut:
            return try await Everyday.runShortcut(step.text ?? "")
        case .click:
            return try ScreenControl.click(step.target ?? "")
        case .menu:
            return try ScreenControl.menu(step.target ?? "")
        case .typeInto:
            return try await ScreenControl.typeInto(step.target ?? "", text: step.text ?? "")
        case .scroll:
            return try ScreenControl.scroll(step.text ?? "down", pages: step.number ?? 1)
        case .pressKey:
            return try ScreenControl.pressKey(step.text ?? "")
        case .goBack:
            return try ScreenControl.goBack()
        case .calculate:
            let spoken = step.text ?? ""
            guard let value = Arithmetic.evaluate(spoken), let expression = Arithmetic.expression(spoken) else {
                throw SkillError.failed("Couldn't work out \"\(spoken)\".")
            }
            // "open calculator and add 5+5": show it in Calculator too.
            if MacControl.frontmostBundleID() == "com.apple.calculator" {
                _ = try? ScreenControl.pressKey("escape")
                MacControl.typeCharacters(expression.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") + "=")
            }
            return "\(expression) = \(Arithmetic.format(value))"
        }
    }
}
