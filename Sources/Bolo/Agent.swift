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
        let flag = cancelFlag
        executor.isCancelled = { flag.value }
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
        guard phase == .idle || phase == .done || phase == .failed else { return }
        hideTask?.cancel()
        cancelled = false
        transcript = ""
        rows = []
        message = nil
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
        set(.working)
        let conf = heard.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        Log.agent.notice("heard: \(text, privacy: .public) (confidence \(conf, privacy: .public), \(heard.alternatives.count) alternatives)")
        guard var command = await understand(heard) else {
            Log.agent.notice("not understood")
            fail("Didn't catch a command. Try \"open Notes\" or \"bhai ko WhatsApp karo …\".")
            History.append(utterance: text, command: nil, results: [])
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
        rows = command.steps.map { Row(text: $0.summary, status: .pending) }
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
                results.append("error: \(error.localizedDescription)")
                Log.skills.error("failed: \(step.summary, privacy: .public): \(error.localizedDescription, privacy: .public)")
                History.append(utterance: text, command: command, results: results)
                // Later steps may depend on this one, so stop here.
                fail(error.localizedDescription)
                return
            }
        }
        History.append(utterance: text, command: command, results: results)
        set(cancelled ? .failed : .done)
        scheduleHide(after: 2.5)
    }

    func understand(_ heard: Heard) async -> Command? {
        usedAlternative = false
        if let (command, index) = parser.parse(candidates: heard.candidates) {
            if index > 0 {
                usedAlternative = true
                Log.agent.notice("used alternative #\(index): \(command.utterance, privacy: .public)")
            }
            return command
        }
        guard settings.useModelFallback else { return nil }
        message = "Thinking…"
        defer { message = nil }
        let text = HearingFixes.apply(heard.text)
        if usesQwen {
            do { return try await qwen.plan(text) } catch {
                Log.agent.error("Qwen failed, using Apple's model: \(error.localizedDescription, privacy: .public)")
            }
        }
        return try? await planner?.plan(text)
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
