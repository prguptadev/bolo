import Foundation

/// What was said and done in the last few minutes, so follow-ups work: "open Chrome and google.com",
/// then "now open my Gmail", then "click on Updates"; or "list the files in my project", then
/// "rename the first one to notes.md". Forgotten after `idleMinutes` without a command.
public struct Conversation: Sendable {
    public struct Turn: Sendable, Equatable {
        public let utterance: String
        public let did: [String]
        public let date: Date
    }

    public private(set) var turns: [Turn] = []
    /// The folder the terminal work is in, carried between commands.
    public var workingDirectory: String?
    /// The person last messaged or talked about ("tell him…").
    public private(set) var lastContact: String?
    public var idleMinutes: Double

    public init(idleMinutes: Double = 10) {
        self.idleMinutes = idleMinutes
    }

    public mutating func record(utterance: String, steps: [Step], results: [String], at date: Date = Date()) {
        var did: [String] = []
        for (i, step) in steps.enumerated() {
            let result = i < results.count ? results[i] : "not done"
            did.append(step.summary == result ? result : "\(step.summary) → \(result)")
            if let c = step.contact, [.sendMessage, .draftMessage, .call].contains(step.action) { lastContact = c }
        }
        if steps.isEmpty { did = results }
        turns.append(Turn(utterance: utterance, did: did.map { Self.short($0, 300) }, date: date))
        if turns.count > 8 { turns.removeFirst(turns.count - 8) }
    }

    /// Records an agent run: its steps are already short lines.
    public mutating func record(utterance: String, did: [String], at date: Date = Date()) {
        turns.append(Turn(utterance: utterance, did: did.suffix(8).map { Self.short($0, 300) }, date: date))
        if turns.count > 8 { turns.removeFirst(turns.count - 8) }
    }

    public mutating func expireIfIdle(now: Date = Date()) {
        guard let last = turns.last, now.timeIntervalSince(last.date) > idleMinutes * 60 else { return }
        turns = []
        lastContact = nil
        workingDirectory = nil
    }

    public var isEmpty: Bool { turns.isEmpty }

    /// Everything said earlier in this conversation, for grounding follow-ups ("tell him…").
    public var recentUtterances: [String] { turns.map(\.utterance) }

    /// For the model: the last few turns, oldest first.
    public func render(maxTurns: Int = 5) -> String {
        guard !turns.isEmpty else { return "" }
        var lines = ["Earlier in this conversation (oldest first):"]
        for t in turns.suffix(maxTurns) {
            lines.append("- User said: \"\(t.utterance)\"")
            if !t.did.isEmpty { lines.append("  Bolo did: " + t.did.joined(separator: "; ")) }
        }
        if let workingDirectory { lines.append("Terminal folder: \(workingDirectory)") }
        return lines.joined(separator: "\n")
    }

    public static func short(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return one.count > n ? String(one.prefix(n)) + "…" : one
    }
}
