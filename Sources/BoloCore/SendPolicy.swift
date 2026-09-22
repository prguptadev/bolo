import Foundation

/// When Bolo may send on its own. Anything it isn't sure it heard right is typed as a draft instead:
/// the message still appears in the chat, you glance and press Enter.
///
/// Measured on the 50 recordings (eval/results/speech-*.md): clear English scored 0.73–0.96
/// confidence; garbled Hinglish message bodies ("Mein Ghar Ponj Gya") scored 0.45–0.49.
public enum SendPolicy {
    public struct Decision {
        public var command: Command
        /// Why sends became drafts, for the notch; nil when nothing changed.
        public var reason: String?
    }

    public static func apply(_ command: Command, confidence: Double?, minConfidence: Double, usedAlternative: Bool) -> Decision {
        let sends = command.steps.contains { $0.action == .sendMessage || $0.action == .call }
        let unsure: String? =
            usedAlternative ? "Understood it only from a second guess, so the message is a draft, not sent."
            : (confidence.map { $0 < minConfidence } ?? false) ? "Heard it unclearly, so the message is a draft, not sent."
            : nil
        guard sends, let reason = unsure else { return Decision(command: command, reason: nil) }
        var c = command
        c.steps = c.steps.compactMap { s in
            var s = s
            if s.action == .call { return nil }
            if s.action == .sendMessage { s.action = .draftMessage }
            return s
        }
        return Decision(command: c, reason: reason)
    }
}
