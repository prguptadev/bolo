import BoloCore
import Foundation

/// Runs one step with the right skill and returns a short line for the notch.
final class Executor {
    let settings: Settings
    let contacts: ContactBook
    var installedApps: [String: URL]
    var isCancelled: () -> Bool = { false }

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
            let send = step.action == .sendMessage
            let text = step.text ?? ""
            do {
                let person = try contacts.resolve(step.contact ?? "")
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
        }
    }
}
