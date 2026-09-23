import BoloCore
import Foundation

/// The agent loop: look → decide one action → check permission → act → look again, until the model
/// says done, asks something, hits the step limit, or you press Esc.
@MainActor
final class AgentLoop {
    struct Outcome {
        /// One line per step, for the conversation memory.
        var did: [String] = []
        /// What to show at the end: the answer, the question, or why it stopped.
        var message: String?
        var finished = false
    }

    enum RowStatus { case running, ok, failed, pending }

    let brain: Brain
    let tools: Tools
    let level: PermissionLevel
    let maxSteps: Int
    let irreversibleDelay: Double
    var isCancelled: () -> Bool = { false }
    /// Shows a step in the notch. `replace` updates the last row instead of adding one.
    var onRow: (String, RowStatus, _ replace: Bool) -> Void = { _, _, _ in }
    var onMessage: (String?) -> Void = { _ in }
    /// Asks you (by voice) to allow something. Returns false on "no" or silence.
    var confirm: (String) async -> Bool = { _ in false }

    init(brain: Brain, tools: Tools, level: PermissionLevel, maxSteps: Int, irreversibleDelay: Double) {
        self.brain = brain
        self.tools = tools
        self.level = level
        self.maxSteps = maxSteps
        self.irreversibleDelay = irreversibleDelay
    }

    func run(goal: String, conversation: Conversation, alreadyDone: [String] = []) async -> Outcome {
        var outcome = Outcome()
        var history = alreadyDone
        var lastAction: AgentAction?
        var lastFailed = false
        var repeats = 0
        var unreadable = 0
        let memory = Memory.read()
        let context = conversation.render()
        let said = conversation.recentUtterances
        Log.agent.notice("agent goal: \(goal, privacy: .public) (\(self.brain.name, privacy: .public), level \(self.level.rawValue, privacy: .public))")

        for step in 1...max(1, maxSteps) {
            if isCancelled() {
                outcome.message = "Stopped."
                break
            }
            onMessage(step == 1 ? "Looking at the screen…" : "Thinking…")
            let snap = await Observer.snapshot()
            if snap.observation.systemDialog {
                outcome.message = "macOS is asking you for a permission. Answer it, then say it again."
                Log.agent.notice("stopped: system permission prompt in front")
                break
            }
            let hints = Skills.hints(app: snap.observation.app, bundleID: snap.bundleID)
            let prompt = AgentPrompt.turn(
                goal: goal, context: context, memory: memory, screen: snap.observation.render(), history: history,
                step: step, maxSteps: maxSteps, hints: hints)
            let reply: String
            let started = Date()
            do {
                reply = try await brain.respond(system: AgentPrompt.system, prompt: prompt, maxTokens: 1200)
            } catch {
                outcome.message = "The brain failed: \(error.localizedDescription)"
                Log.agent.error("brain failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            Log.agent.notice("step \(step) (\(Int(Date().timeIntervalSince(started) * 1000)) ms, \(prompt.count) chars in): \(Conversation.short(reply, 400), privacy: .public)")
            guard let action = AgentAction.parse(reply) else {
                unreadable += 1
                history.append("(your reply wasn't a valid action JSON; reply with exactly one JSON object)")
                if unreadable >= 2 {
                    outcome.message = "I couldn't work out a next step for that."
                    break
                }
                continue
            }
            onMessage(action.thought.map { Conversation.short($0, 120) })

            if action.tool == .done {
                outcome.finished = true
                outcome.message = action.text ?? "Done"
                if history.isEmpty { onRow(outcome.message ?? "Done", .ok, false) }
                break
            }
            if action.tool == .ask {
                outcome.message = action.text ?? "What exactly should I do?"
                break
            }

            // The same action again after it failed: the model is stuck.
            if let last = lastAction, last == action {
                repeats += 1
                if lastFailed || repeats >= 2 {
                    history.append("(you repeated the same action; it didn't help. Try a different way or reply ask)")
                    if repeats >= 3 {
                        outcome.message = "I kept trying the same thing without progress, so I stopped."
                        break
                    }
                    continue
                }
            } else {
                repeats = 0
            }
            lastAction = action

            // Never, at any level.
            if let why = action.forbidden(elementRole: action.id.flatMap { snap.role(of: $0) }) {
                history.append("\(action.summary) → refused: \(why)")
                onRow("\(action.summary) · \(why)", .failed, false)
                lastFailed = true
                continue
            }

            // Permission for this level.
            var risk = action.risk(inChatApp: AppHints.chatApps.contains(snap.bundleID ?? ""))
            if action.tool == .writeFile, let p = action.path, FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath) {
                risk = .destructive  // overwriting
            }
            switch AgentPolicy.verdict(risk, level: level) {
            case .allow:
                break
            case .deny(let why):
                history.append("\(action.summary) → not allowed: \(why)")
                onRow("\(action.summary) · not allowed at this permission level", .failed, false)
                lastFailed = true
                continue
            case .confirm:
                onRow("\(action.summary) · say \"yes\" to allow", .pending, false)
                let ok = await confirm(action.summary)
                guard ok else {
                    onRow("\(action.summary) · not done", .failed, true)
                    outcome.message = "OK, not doing that."
                    break
                }
            case .countdown:
                onRow("\(action.summary) in \(Int(irreversibleDelay)) s · Esc stops it", .pending, false)
                for _ in 0..<Int(max(0, irreversibleDelay) * 10) {
                    if isCancelled() { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if isCancelled() {
                    onRow("\(action.summary) · stopped", .failed, true)
                    outcome.message = "Stopped."
                    break
                }
            }
            if outcome.message != nil { break }

            onRow(action.summary, .running, [.confirm, .countdown].contains(AgentPolicy.verdict(risk, level: level)))
            do {
                let result = try await tools.run(action, seeing: snap, goal: goal, said: said)
                let shown = action.tool == .readFile || action.tool == .shell || action.tool == .listFiles
                    ? action.summary + " · " + Conversation.short(result.split(separator: "\n").first.map(String.init) ?? "done", 70)
                    : Conversation.short(result, 110)
                onRow(shown, .ok, true)
                history.append("\(action.summary) → \(Conversation.short(result, 1500))")
                outcome.did.append(Conversation.short("\(action.summary) → \(result)", 200))
                lastFailed = false
                Log.skills.notice("agent ok: \(Conversation.short(result, 200), privacy: .public)")
                if action.last {
                    outcome.finished = true
                    outcome.message = nil
                    break
                }
            } catch {
                onRow("\(action.summary) · \(error.localizedDescription)", .failed, true)
                history.append("\(action.summary) → failed: \(error.localizedDescription)")
                outcome.did.append("\(action.summary) → failed: \(Conversation.short(error.localizedDescription, 120))")
                lastFailed = true
                Log.skills.error("agent failed: \(action.summary, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            // Let the app catch up before looking again.
            let settle: Double = [.openApp, .openURL, .openFile].contains(action.tool) ? 1.5 : [.click, .key, .menu].contains(action.tool) ? 0.7 : 0.2
            try? await Task.sleep(for: .seconds(settle))
        }
        if outcome.message == nil, !outcome.finished {
            outcome.message = "Reached \(maxSteps) steps. Say what to do next."
        }
        return outcome
    }
}
