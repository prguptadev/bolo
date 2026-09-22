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
        let messaging = Messaging(settings: settings, isCancelled: isCancelled)
        switch step.action {
        case .sendMessage, .draftMessage:
            let person = try contacts.resolve(step.contact ?? "")
            let channel = step.channel ?? person.channel ?? .whatsapp
            return try await messaging.send(step, to: person, channel: channel, send: step.action == .sendMessage)
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
        }
    }
}
