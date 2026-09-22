import Foundation

/// Rejects model output that isn't backed by what the user actually said.
///
/// Measured on this Mac: for "new note groceries milk eggs bread" Apple's on-device model added a
/// WhatsApp message to "Priya" that the user never said. Bolo acts without asking, so every
/// contact and every word it sends must come from the utterance.
public enum Grounding {
    private static let fillers: Set<String> = [
        "a", "an", "the", "to", "and", "or", "of", "on", "in", "at", "for", "is", "it", "i", "me", "my",
        "please", "saying", "that", "ko", "ki", "karo",
    ]

    static func words(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}' ]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    /// Share of `phrase`'s meaningful words that also appear in `utterance` (1.0 when nothing to check).
    public static func share(of phrase: String, in utterance: String) -> Double {
        let said = Set(words(utterance))
        let wanted = words(phrase).filter { !fillers.contains($0) }
        guard !wanted.isEmpty else { return 1 }
        return Double(wanted.filter(said.contains).count) / Double(wanted.count)
    }

    /// Keeps only steps whose slots come from the utterance. Returns nil when nothing safe is left,
    /// or when any message/call step is ungrounded (never drop half of a send and run the rest).
    public static func filter(_ command: Command) -> Command? {
        let u = command.utterance
        var kept: [Step] = []
        for var step in command.steps {
            // Text the model wrote (a joke, an email, an answer) can't be checked against your words.
            // It may go into notes, drafts, typing and the notch, but is never sent: sends become drafts.
            if step.generated == true, let t = step.text, !t.isEmpty {
                switch step.action {
                case .newNote, .typeText, .answer:
                    kept.append(step)
                    continue
                case .sendMessage, .draftMessage:
                    guard let who = step.contact, share(of: who, in: u) == 1 else { return nil }
                    step.action = .draftMessage
                    kept.append(step)
                    continue
                default:
                    break
                }
            }
            let contactOK = step.contact.map { share(of: $0, in: u) == 1 } ?? false
            let textOK = step.text.map { share(of: $0, in: u) >= 0.8 } ?? true
            switch step.action {
            case .sendMessage, .draftMessage, .call:
                guard contactOK, textOK else { return nil }
                kept.append(step)
            case .newNote, .typeText, .addReminder, .runShortcut:
                if (step.text ?? "").isEmpty == false, textOK { kept.append(step) }
            case .answer, .lookup:
                if step.text?.isEmpty == false { kept.append(step) }
            case .system:
                // Risky operations (empty the bin, restart, quit…) only if you said the words for them.
                guard let op = SystemOp(rawValue: step.target ?? "") else { continue }
                if let words = op.mustHear, u.range(of: "\\b(?:" + words + ")", options: [.regularExpression, .caseInsensitive]) == nil { continue }
                if op == .quitApp || op == .hideApp {
                    guard let app = step.app, share(of: app, in: u) > 0 || appSpoken(app, in: u) else { continue }
                }
                kept.append(step)
            case .webSearch, .calculate:
                if let t = step.text, share(of: t, in: u) >= 0.6 { kept.append(step) }
            case .openApp:
                if let app = step.app, share(of: app, in: u) > 0 || appSpoken(app, in: u) { kept.append(step) }
            case .openURL:
                if let t = step.text, share(of: t, in: u) > 0 { kept.append(step) }
            case .joinNextMeeting, .setVolume, .mute, .unmute, .lockScreen, .scroll, .goBack:
                kept.append(step)
            case .click, .menu:
                if let t = step.target, share(of: t.replacingOccurrences(of: ">", with: " "), in: u) >= 0.6 { kept.append(step) }
            case .typeInto:
                if let t = step.target, share(of: t, in: u) >= 0.6, textOK, step.text != nil { kept.append(step) }
            case .pressKey:
                // A model pressing Return in a chat would send; only keys the user named.
                if let k = step.text, share(of: k.replacingOccurrences(of: "+", with: " ").replacingOccurrences(of: "cmd", with: "command"), in: u) >= 0.5 { kept.append(step) }
            }
        }
        // Models pad plans with repeats; drop exact duplicates.
        var unique: [Step] = []
        for s in kept where !unique.contains(s) { unique.append(s) }
        guard !unique.isEmpty else { return nil }
        return Command(utterance: u, steps: unique, source: command.source)
    }

    /// What Apple's on-device model may do on its own. Measured in eval/results/text-2026-09-22.md:
    /// it turned "jot down call the plumber tomorrow" into a call and "I was thinking about messaging
    /// bhai later" into typing. So its sends become drafts, and calls, typing and locking are dropped.
    public static func limitModel(_ command: Command) -> Command? {
        var steps: [Step] = []
        for var s in command.steps {
            switch s.action {
            case .call, .typeText, .lockScreen, .click, .menu, .typeInto, .pressKey, .scroll, .goBack:
                continue
            case .system where SystemOp(rawValue: s.target ?? "").map({ $0.mustHear != nil }) ?? true:
                continue
            case .sendMessage:
                s.action = .draftMessage
            default:
                break
            }
            steps.append(s)
        }
        return steps.isEmpty ? nil : Command(utterance: command.utterance, steps: steps, source: command.source)
    }

    /// "Microsoft Teams" is fine when the user said "teams".
    private static func appSpoken(_ app: String, in utterance: String) -> Bool {
        let said = utterance.lowercased()
        return AppNames.aliases.contains { said.contains($0.key) && $0.value.lowercased() == app.lowercased() }
    }
}
