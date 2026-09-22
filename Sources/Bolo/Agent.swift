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
    private var parser = CommandParser()
    private var cancelled = false
    private var hideTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?

    init(settings: Settings) {
        self.settings = settings
        executor = Executor(settings: settings, contacts: contacts)
        speech = SpeechEngine(settings: settings)
        executor.isCancelled = { [weak self] in MainActor.assumeIsolated { self?.cancelled ?? true } }
        speech.onText = { [weak self] in self?.transcript = $0 }
        speech.onLevel = { [weak self] in self?.level = $0 }
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
                set(.idle)
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

    func handle(_ heard: Heard) async {
        let text = heard.text
        lastUtterance = text
        transcript = text
        set(.working)
        let conf = heard.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        Log.agent.info("heard: \(text, privacy: .public) (confidence \(conf, privacy: .public), \(heard.alternatives.count) alternatives)")
        guard var command = await understand(heard) else {
            Log.agent.info("not understood")
            fail("Didn't catch a command. Try \"open Notes\" or \"bhai ko WhatsApp karo …\".")
            History.append(utterance: text, command: nil, results: [])
            return
        }
        // Heard unclearly: type messages as drafts rather than sending misheard words.
        if let c = heard.confidence, c < settings.minSendConfidence, command.steps.contains(where: { $0.action == .sendMessage || $0.action == .call }) {
            command.steps = command.steps.compactMap { s in
                var s = s
                if s.action == .call { return nil }
                if s.action == .sendMessage { s.action = .draftMessage }
                return s
            }
            message = "Heard it unclearly, so the message is a draft, not sent."
            Log.agent.info("low confidence \(conf, privacy: .public): sends downgraded to drafts")
        }
        Log.agent.info("\(command.source.rawValue, privacy: .public): \(command.steps.map(\.summary).joined(separator: " | "), privacy: .public)")
        rows = command.steps.map { Row(text: $0.summary, status: .pending) }
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
                Log.skills.info("ok: \(result, privacy: .public)")
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
        if let (command, index) = parser.parse(candidates: heard.candidates) {
            if index > 0 { Log.agent.info("used alternative #\(index): \(command.utterance, privacy: .public)") }
            return command
        }
        guard settings.useModelFallback, let planner else { return nil }
        message = "Thinking…"
        defer { message = nil }
        return try? await planner.plan(HearingFixes.apply(heard.text))
    }

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
