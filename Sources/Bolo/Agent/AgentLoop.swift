import AppKit
import BoloCore
import Foundation

/// The agent loop: look → decide one action → check permission → act → look again, until the model
/// says done, asks something, hits the step limit, or you press Esc.
///
/// One chat session per task: the system prompt and earlier steps stay in the model's cache, so each
/// step only feeds the new screen (about a third of the time of re-sending everything).
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

    /// Tools whose effect lands in whatever app has the keyboard or is in front.
    private static let needsFront: Set<AgentAction.Tool> = [.click, .fill, .type, .key, .menu, .scroll, .tab]
    /// Tools that may legitimately change which app the agent works in.
    private static let mayChangeApp: Set<AgentAction.Tool> = [.openApp, .openFile, .openURL, .system, .message, .call, .note, .reminder]

    init(brain: Brain, tools: Tools, level: PermissionLevel, maxSteps: Int, irreversibleDelay: Double) {
        self.brain = brain
        self.tools = tools
        self.level = level
        self.maxSteps = maxSteps
        self.irreversibleDelay = irreversibleDelay
    }

    func run(goal: String, alternatives: [String] = [], conversation: Conversation, alreadyDone: [String] = []) async -> Outcome {
        var outcome = Outcome()
        var history = alreadyDone
        var lastAction: AgentAction?
        var lastFailed = false
        var repeats = 0
        var unreadable = 0
        /// The app the agent works in. If you switch to another app meanwhile, the agent keeps
        /// looking at (and returns to) this one instead of following you around.
        var working = MacControl.frontApp()
        var lastBundle: String?
        var lastScreen: String?
        var result: String?
        let memory = Memory.read()
        let context = conversation.render()
        let said = conversation.recentUtterances
        Log.agent.notice("agent goal: \(goal, privacy: .public) (\(self.brain.name, privacy: .public), level \(self.level.rawValue, privacy: .public))")

        // Keys, clicks and typing would land on the login screen. (Opening apps, notes and reminders
        // don't need the screen, but a locked Mac usually means nobody's watching the notch.)
        if MacControl.isScreenLocked {
            outcome.message = "The Mac is locked. Unlock it and say it again."
            return outcome
        }
        onMessage("Thinking…")
        let session: BrainSession
        do {
            session = try await brain.startTask(system: AgentPrompt.system, maxTokens: 1200)
        } catch {
            outcome.message = "The brain failed: \(error.localizedDescription)"
            return outcome
        }

        for step in 1...max(1, maxSteps) {
            if isCancelled() {
                outcome.message = "Stopped."
                break
            }
            onMessage(step == 1 ? "Looking at the screen…" : "Thinking…")
            if let w = working, w.isTerminated { working = MacControl.frontApp() }
            let snap = await Observer.snapshot(target: working, goal: goal)
            Log.agent.notice("screen: \(Conversation.short(snap.observation.render(), 700), privacy: .public)")
            if snap.observation.systemDialog {
                outcome.message = "macOS is asking you for a permission. Answer it, then say it again."
                Log.agent.notice("stopped: system permission prompt in front")
                break
            }
            let appChanged = snap.bundleID != lastBundle
            lastBundle = snap.bundleID
            let hints = appChanged || step % 4 == 1 ? Skills.hints(app: snap.observation.app, bundleID: snap.bundleID) : nil
            let screen = snap.observation.render(includeMenus: appChanged)
            // A shell command or a file write rarely changes the window: don't resend it.
            let signature = snap.observation.signature
            let prompt = AgentPrompt.turn(
                goal: goal, alternatives: alternatives, context: context, memory: memory,
                screen: step > 1 && signature == lastScreen ? nil : screen,
                history: AgentPrompt.trimmed(history), step: step, maxSteps: maxSteps, hints: hints)
            lastScreen = signature
            let reply: String
            let started = Date()
            do {
                reply = try await session.respond(prompt)
            } catch {
                outcome.message = "The brain failed: \(error.localizedDescription)"
                Log.agent.error("brain failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            Log.agent.notice("step \(step) (\(Int(Date().timeIntervalSince(started) * 1000)) ms, \(prompt.count) chars in): \(Conversation.short(reply, 400), privacy: .public)")
            guard let action = AgentAction.parse(reply) else {
                unreadable += 1
                result = "That wasn't a valid action. Reply with exactly one JSON object, nothing else."
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
                    result = "You repeated \(action.summary) and it didn't help. Do something different, or reply ask."
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
            let pointedAt = action.id.flatMap { snap.label(of: $0) }
            if let why = action.forbidden(elementLabel: pointedAt, elementRole: action.id.flatMap { snap.role(of: $0) }) {
                result = "\(action.summary) → refused: \(why)"
                history.append(result!)
                onRow("\(action.summary) · \(why)", .failed, false)
                lastFailed = true
                continue
            }

            // Permission for this level.
            var risk = action.risk(inChatApp: AppHints.chatApps.contains(snap.bundleID ?? ""), elementLabel: pointedAt)
            if action.tool == .writeFile, let p = action.path, FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath) {
                risk = .destructive  // overwriting
            }
            let verdict = AgentPolicy.verdict(risk, level: level)
            switch verdict {
            case .allow:
                break
            case .deny(let why):
                result = "\(action.summary) → not allowed: \(why)"
                history.append(result!)
                onRow("\(action.summary) · not allowed at this permission level", .failed, false)
                lastFailed = true
                continue
            case .confirm:
                onRow("\(action.summary) · say \"yes\" to allow", .pending, false)
                Log.agent.notice("waiting for a spoken yes: \(action.summary, privacy: .public)")
                let ok = await confirm(action.summary)
                Log.agent.notice("spoken confirmation: \(ok ? "yes" : "no or silence", privacy: .public)")
                guard ok else {
                    onRow("\(action.summary) · not done", .failed, true)
                    outcome.message = "Not done: it needed a \"yes\"."
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

            // Keys, typing and clicks go to the app in front: make sure that's the one we're working in.
            if Self.needsFront.contains(action.tool), let w = working, !w.isActive {
                w.activate()
                try? await Task.sleep(for: .milliseconds(500))
            }
            onRow(action.summary, .running, verdict != .allow)
            do {
                let output = try await tools.run(action, seeing: snap, goal: goal, said: said)
                let shown = action.tool == .readFile || action.tool == .shell || action.tool == .listFiles
                    ? action.summary + " · " + Conversation.short(output.split(separator: "\n").first.map(String.init) ?? "done", 70)
                    : Conversation.short(output, 110)
                onRow(shown, .ok, true)
                result = "\(action.summary) → \(Conversation.short(output, 1500))"
                history.append(result!)
                outcome.did.append(Conversation.short("\(action.summary) → \(output)", 200))
                lastFailed = false
                Log.skills.notice("agent ok: \(Conversation.short(output, 200), privacy: .public)")
                if action.last {
                    outcome.finished = true
                    outcome.message = nil
                    break
                }
            } catch {
                onRow("\(action.summary) · \(error.localizedDescription)", .failed, true)
                result = "\(action.summary) → failed: \(error.localizedDescription)"
                history.append(result!)
                outcome.did.append("\(action.summary) → failed: \(Conversation.short(error.localizedDescription, 120))")
                lastFailed = true
                Log.skills.error("agent failed: \(action.summary, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            // Let the app catch up before looking again.
            let settle: Double = [.openApp, .openURL, .openFile].contains(action.tool) ? 1.5 : [.click, .key, .menu, .tab].contains(action.tool) ? 0.7 : 0.2
            try? await Task.sleep(for: .seconds(settle))
            // Our own action opened or switched to another app: work there from now on.
            if Self.mayChangeApp.contains(action.tool), let front = MacControl.frontApp(), front.processIdentifier != working?.processIdentifier {
                working = front
            }
        }
        if outcome.message == nil, !outcome.finished {
            outcome.message = "Reached \(maxSteps) steps. Say what to do next."
        }
        return outcome
    }
}
