import AppKit
import BoloCore
import Foundation

/// Hold key -> listen -> understand -> act, fully autonomously. Owns the state the notch shows.
@MainActor
final class Agent: ObservableObject {
    enum Phase { case idle, listening, working, done, failed }

    struct Row: Identifiable {
        enum Status { case pending, running, ok, failed }
        let id = UUID()
        var text: String
        var status: Status
        /// Answers get room in the notch; action rows stay one or two lines.
        var isAnswer = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var rows: [Row] = []
    @Published private(set) var message: String?
    @Published private(set) var level: Float = 0
    @Published private(set) var lastUtterance: String?

    var onPhaseChange: ((Phase) -> Void)?

    private let settings: Settings
    private let contacts = ContactBook()
    private let executor: Executor
    private let speech: SpeechEngine
    private let planner = try? ModelPlanner()
    private let qwen: QwenPlanner
    private let tools: Tools
    private var conversation: Conversation
    /// A "say yes" question the agent loop is waiting on: the next thing you say answers it.
    private var pendingConfirmation: CheckedContinuation<Bool, Never>?
    private var confirmationTimeout: Task<Void, Never>?
    private var parser = CommandParser()
    /// Read from background tasks (skills' wait loops), so it can't be main-actor state.
    private let cancelFlag = CancelFlag()
    private var cancelled: Bool {
        get { cancelFlag.value }
        set { cancelFlag.value = newValue }
    }
    private var usedAlternative = false
    private var hideTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init(settings: Settings) {
        self.settings = settings
        executor = Executor(settings: settings, contacts: contacts)
        speech = SpeechEngine(settings: settings)
        qwen = QwenPlanner(idleSeconds: settings.brainIdleSeconds)
        executor.qwen = qwen
        tools = Tools(settings: settings, contacts: contacts, executor: executor)
        tools.qwen = qwen
        conversation = Conversation(idleMinutes: settings.conversationMinutes)
        let flag = cancelFlag
        executor.isCancelled = { flag.value }
        tools.isCancelled = { flag.value }
        speech.onText = { [weak self] in self?.transcript = $0 }
        speech.onLevel = { [weak self] in self?.level = $0 }
        speech.prepare()
        Task { await reloadNames() }
    }

    /// Re-reads Contacts, the nicknames file and installed apps.
    func reloadNames() async {
        await contacts.reload()
        executor.installedApps = Everyday.installedApps()
        let names = contacts.spokenNames
        let apps = Set(executor.installedApps.keys).union(AppNames.aliases.keys)
        parser = CommandParser(knownNames: names, knownApps: apps)
        let appNames = executor.installedApps.values.map { $0.deletingPathExtension().lastPathComponent }
        // Words the speech engine should favour: people, apps, and Hinglish command words.
        speech.contextualStrings = Array(Set(names.filter { $0.count > 2 } + appNames + Self.commandWords))
        if settings.customVocabulary, settings.speechEngine == "dictation" {
            speech.languageModel = await CustomVocabulary.prepare(
                locale: Locale(identifier: settings.speechLocale), names: names, apps: appNames)
        }
    }

    private static let commandWords = [
        "WhatsApp", "Teams", "iMessage", "karo", "bhejo", "kholo", "likho", "bol do", "bolo", "yaad dilana",
        "bhai", "mummy", "papa", "remind me", "new note", "join my next meeting",
    ]

    // MARK: Key events

    func keyPressed() {
        // While the agent waits for "yes", the key records the answer.
        guard phase == .idle || phase == .done || phase == .failed || pendingConfirmation != nil else { return }
        hideTask?.cancel()
        if pendingConfirmation == nil {
            cancelled = false
            transcript = ""
            rows = []
            message = nil
        }
        set(.listening)
        executor.frontAtStart = MacControl.frontmostBundleID()
        // Warm the brain while you talk, in case the phrase rules can't read the sentence.
        if usesQwen { Task { try? await qwen.load() } }
        startTask = Task {
            do {
                try await speech.start()
            } catch {
                Log.speech.error("start failed: \(error.localizedDescription, privacy: .public)")
                fail("Couldn't start the microphone: \(error.localizedDescription)")
            }
        }
    }

    func keyReleased() {
        guard phase == .listening else { return }
        Task {
            await startTask?.value
            let heard = await speech.stop()
            if pendingConfirmation != nil {
                transcript = heard.text
                await handle(heard)
                return
            }
            transcript = heard.text
            guard !heard.text.isEmpty else {
                // Say why nothing happened, instead of silently closing the notch.
                if speech.stats.buffers == 0 {
                    fail("No audio from the microphone. Check System Settings › Privacy & Security › Microphone › Bolo.")
                } else if speech.stats.maxLevel < 0.02 {
                    fail("Too quiet: didn't hear any speech. Hold right ⌥ while you talk.")
                } else {
                    fail("Didn't catch that. Try again, a little closer to the Mac.")
                }
                return
            }
            await handle(heard)
        }
    }

    /// Another key was typed while holding Option: that was typing, not talking.
    func keyCancelled() {
        guard phase == .listening else { return }
        Task {
            await startTask?.value
            await speech.cancel()
            set(.idle)
        }
    }

    func escape() {
        if let waiting = pendingConfirmation {
            pendingConfirmation = nil
            confirmationTimeout?.cancel()
            waiting.resume(returning: false)
            return
        }
        switch phase {
        case .listening: keyCancelled()
        case .working:
            cancelled = true
            message = "Stopping…"
        case .done, .failed: set(.idle)
        case .idle: break
        }
    }

    // MARK: Understand and act

    func handleRemote(_ text: String, act: Bool) async {
        executor.frontAtStart = MacControl.frontmostBundleID()
        await handle(Heard(text: text), act: act)
    }

    /// `act: false` shows and logs the plan without running it (remote dry runs).
    func handle(_ heard: Heard, act: Bool = true) async {
        let text = heard.text
        lastUtterance = text
        transcript = text
        let conf = heard.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        Log.agent.notice("heard: \(text, privacy: .public) (confidence \(conf, privacy: .public), \(heard.alternatives.count) alternatives)")
        // The agent asked "say yes": this is the answer.
        if let waiting = pendingConfirmation {
            pendingConfirmation = nil
            confirmationTimeout?.cancel()
            let yes = text.range(of: "^\\W*(yes|yeah|yep|ya|haan|ha|han|ok|okay|sure|go ahead|do it|karo|kar do|theek hai|confirm|allow)\\b", options: [.regularExpression, .caseInsensitive]) != nil
            Log.agent.notice("confirmation: \(yes ? "yes" : "no", privacy: .public)")
            waiting.resume(returning: yes)
            return
        }
        guard phase != .working else {
            Log.agent.notice("busy: ignored")
            return
        }
        set(.working)
        conversation.expireIfIdle()
        guard var command = await understand(heard) else {
            guard act else {
                message = "Dry run: the phrase rules didn't match; the agent would take this."
                set(.done)
                scheduleHide(after: 4)
                return
            }
            await runAgent(goal: text, alreadyDone: [])
            return
        }
        // Not sure it heard right (low confidence, or only a second guess made sense): drafts, not sends.
        let decision = SendPolicy.apply(command, confidence: heard.confidence, minConfidence: settings.minSendConfidence, usedAlternative: usedAlternative)
        if let reason = decision.reason {
            command = decision.command
            message = reason
            Log.agent.notice("sends downgraded to drafts (confidence \(conf, privacy: .public), alternative \(self.usedAlternative))")
        }
        Log.agent.notice("\(command.source.rawValue, privacy: .public): \(command.steps.map(\.summary).joined(separator: " | "), privacy: .public)")
        rows = command.steps.map { step in
            let op = step.action == .system ? SystemOp(rawValue: step.target ?? "") : nil
            let text = op?.irreversible == true
                ? "\(step.summary) in \(Int(settings.irreversibleDelaySeconds)) s · Esc stops it" : step.summary
            return Row(text: text, status: .pending, isAnswer: [.answer, .lookup, .calculate].contains(step.action) || op?.answersOnly == true)
        }
        guard act else {
            message = "Dry run: nothing was done."
            set(.done)
            scheduleHide(after: 4)
            return
        }
        var results: [String] = []
        for (i, step) in command.steps.enumerated() {
            if cancelled {
                rows[i].status = .failed
                results.append("cancelled")
                message = "Stopped."
                break
            }
            rows[i].status = .running
            do {
                let result = try await executor.run(step)
                rows[i].status = .ok
                rows[i].text = result
                Log.skills.notice("ok: \(result, privacy: .public)")
                results.append(result)
            } catch {
                rows[i].status = .failed
                rows[i].text = "\(step.summary) · \(error.localizedDescription)"
                results.append("error: \(error.localizedDescription)")
                Log.skills.error("failed: \(step.summary, privacy: .public): \(error.localizedDescription, privacy: .public)")
                History.append(utterance: text, command: command, results: results)
                // Messaging stops are deliberate (unverified box, unknown person): leave them. Anything
                // else ("no app called Gmail", a button not found) the agent can usually do another way.
                let handOver = ![.sendMessage, .draftMessage, .call].contains(step.action) && !cancelled
                if handOver, usesAgent {
                    let done = zip(command.steps, results).map { "\($0.summary) → \($1)" }
                    await runAgent(goal: text, alreadyDone: done)
                    return
                }
                conversation.record(utterance: text, steps: command.steps, results: results)
                fail(error.localizedDescription)
                return
            }
        }
        History.append(utterance: text, command: command, results: results)
        conversation.record(utterance: text, steps: command.steps, results: results)
        set(cancelled ? .failed : .done)
        // Give answers time to be read.
        scheduleHide(after: rows.contains(where: \.isAnswer) ? 12 : 2.5)
    }

    // MARK: The agent loop

    private var usesAgent: Bool {
        settings.useModelFallback && (settings.agentBrain == "endpoint" || QwenPlanner.isDownloaded)
    }

    private var brain: Brain {
        settings.agentBrain == "endpoint"
            ? EndpointBrain(baseURL: settings.endpointURL, model: settings.endpointModel)
            : QwenBrain(qwen: qwen)
    }

    /// Anything the phrase rules can't do in one go: the model looks at the screen and works step by step.
    private func runAgent(goal: String, alreadyDone: [String]) async {
        guard usesAgent else {
            fail("Didn't catch a command, and the brain isn't downloaded (menu bar › Check setup).")
            History.append(utterance: goal, command: nil, results: [])
            return
        }
        let level = PermissionLevel(rawValue: settings.permissionLevel) ?? .standard
        let loop = AgentLoop(brain: brain, tools: tools, level: level, maxSteps: settings.agentMaxSteps, irreversibleDelay: settings.irreversibleDelaySeconds)
        let flag = cancelFlag
        loop.isCancelled = { flag.value }
        loop.onRow = { [weak self] text, status, replace in
            guard let self else { return }
            let s: Row.Status = switch status {
            case .running: .running
            case .ok: .ok
            case .failed: .failed
            case .pending: .pending
            }
            if replace, !rows.isEmpty {
                rows[rows.count - 1].text = text
                rows[rows.count - 1].status = s
            } else {
                rows.append(Row(text: text, status: s))
            }
        }
        loop.onMessage = { [weak self] in self?.message = $0 }
        loop.confirm = { [weak self] _ in await self?.askByVoice() ?? false }
        let outcome = await loop.run(goal: goal, conversation: conversation, alreadyDone: alreadyDone)
        conversation.record(utterance: goal, did: alreadyDone + outcome.did)
        History.append(utterance: goal, command: nil, results: alreadyDone + outcome.did + [outcome.message ?? ""])
        message = outcome.message
        if outcome.finished || cancelled == false && outcome.did.contains(where: { !$0.contains("failed") }) {
            if let m = outcome.message, !outcome.did.isEmpty || rows.isEmpty {
                rows.append(Row(text: m, status: outcome.finished ? .ok : .failed, isAnswer: true))
                message = nil
            }
            set(outcome.finished ? .done : .failed)
        } else {
            set(.failed)
        }
        scheduleHide(after: outcome.finished && (outcome.message ?? "").count < 40 ? 4 : 12)
    }

    /// Shows "say yes" and waits for the next thing you say (25 s), so sends and deletes at the
    /// standard level are yours to allow.
    private func askByVoice() async -> Bool {
        await withCheckedContinuation { cont in
            pendingConfirmation = cont
            message = "Hold the key and say \"yes\" to allow, or anything else to skip."
            confirmationTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, !Task.isCancelled, let waiting = pendingConfirmation else { return }
                pendingConfirmation = nil
                waiting.resume(returning: false)
            }
        }
    }

    func understand(_ heard: Heard) async -> Command? {
        usedAlternative = false
        // "search for Gandhi on that page", "rename it": about what's already there, so the agent, which can see it.
        if usesAgent, !conversation.isEmpty, Self.pointsAtSomething(heard.text) {
            Log.agent.notice("follow-up with context: agent")
            return nil
        }
        if let (command, index) = parser.parse(candidates: heard.candidates) {
            if index > 0 {
                usedAlternative = true
                Log.agent.notice("used alternative #\(index): \(command.utterance, privacy: .public)")
            }
            return command
        }
        guard settings.useModelFallback else { return nil }
        // A follow-up ("now click Updates", "rename it") needs the conversation and the screen: the agent.
        if usesAgent, !conversation.isEmpty || Self.refersToContext(heard.text) { return nil }
        message = "Thinking…"
        defer { message = nil }
        let text = HearingFixes.apply(heard.text)
        if usesQwen {
            do {
                // One quick plan for plain requests; screen work goes to the agent, which can see.
                if let c = try await qwen.plan(text), !c.steps.contains(where: { $0.action.drivesScreen }) { return c }
                return nil
            } catch {
                Log.agent.error("Qwen failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if usesAgent { return nil }
        return try? await planner?.plan(text)
    }

    /// Points at a thing: "that page", "there", "it", "him". Stronger than `refersToContext`.
    private static func pointsAtSomething(_ text: String) -> Bool {
        text.range(of: "\\b(that|this|there|here|it|him|her|them|same|those|these|wahan|yahan|isko|usko|wahi|usi|isme|usme)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Words that point at something already on screen or said before.
    private static func refersToContext(_ text: String) -> Bool {
        text.range(of: "\\b(now|then|next|there|here|this|that|it|him|her|them|same|again|also|too|instead|back|wahan|yahan|isko|usko|phir|ab|wahi|usi)\\b|^(no|nahi|nope)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var usesQwen: Bool { settings.useModelFallback && settings.brain == "qwen" && QwenPlanner.isDownloaded }

    // MARK: State

    private func set(_ p: Phase) {
        phase = p
        onPhaseChange?(p)
    }

    private func fail(_ text: String) {
        message = text
        set(.failed)
        scheduleHide(after: 5)
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, phase == .done || phase == .failed else { return }
            set(.idle)
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// One JSON line per command in ~/Library/Application Support/Bolo/history.jsonl.
enum History {
    private struct Entry: Encodable {
        let date: Date
        let utterance: String
        let command: Command?
        let results: [String]
    }

    static func append(utterance: String, command: Command?, results: [String]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(Entry(date: Date(), utterance: utterance, command: command, results: results)) else { return }
        line.append(0x0A)
        let url = Settings.historyURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
