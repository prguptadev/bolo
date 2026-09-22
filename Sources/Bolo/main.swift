import AppKit
import BoloCore
import Foundation

// Bolo.app/Contents/MacOS/Bolo                       -> menu-bar app
// Bolo --say "open notes" [--dry-run] [--no-model]    -> run one command from the terminal
// Bolo --doctor                                       -> what this Mac still needs
// Bolo --listen [seconds] [--no-noise]                -> live transcript in Terminal; shows what Bolo would do
// Bolo --remote "sentence" [--dry-run]                -> run it inside the running Bolo.app (token-protected)
// Bolo --batch prompts.jsonl [--names a,b] [--no-model] -> understand each {"id","say"} line, print JSONL (never acts)
let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let path = value(after: "--batch") {
    Task { @MainActor in
        struct Prompt: Decodable { let id: String; let say: String; let alts: [String]?; let conf: Double? }
        let minConfidence = Settings.load().minSendConfidence
        struct Row: Encodable { let id: String; let source: String?; let steps: [Step]; let ms: Int }
        let names = value(after: "--names")?.split(separator: ",").map(String.init) ?? []
        let apps = Everyday.installedApps()
        let parser = CommandParser(knownNames: names, knownApps: Set(apps.keys).union(AppNames.aliases.keys))
        // --brain apple (default, as in the eval) | qwen | none
        let brain = args.contains("--no-model") ? "none" : (value(after: "--brain") ?? "apple")
        let planner = brain == "apple" ? try? ModelPlanner() : nil
        let qwen = brain == "qwen" ? QwenPlanner(idleSeconds: 600) : nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n") ?? []
        for line in lines {
            guard let p = try? JSONDecoder().decode(Prompt.self, from: Data(line.utf8)) else { continue }
            let started = Date()
            let parsed = parser.parse(candidates: [p.say] + (p.alts ?? []))
            var command = parsed?.command
            if command == nil, let planner { command = try? await planner.plan(HearingFixes.apply(p.say)) }
            if command == nil, let qwen { command = try? await qwen.plan(HearingFixes.apply(p.say)) }
            if let c = command {
                command = SendPolicy.apply(c, confidence: p.conf, minConfidence: minConfidence, usedAlternative: (parsed?.index ?? 0) > 0).command
            }
            let row = Row(id: p.id, source: command?.source.rawValue, steps: command?.steps ?? [], ms: Int(Date().timeIntervalSince(started) * 1000))
            print(String(data: try! enc.encode(row), encoding: .utf8)!)
        }
        exit(0)
    }
    RunLoop.main.run()
} else if args.contains("--download-brain") || args.contains("--test-brain") {
    // Downloads Qwen3.5-4B (~3.1 GB, once) and runs one sentence through it.
    Task { @MainActor in
        let qwen = QwenPlanner(idleSeconds: 60)
        do {
            print(QwenPlanner.isDownloaded ? "Qwen is downloaded; loading…" : "Downloading \(QwenPlanner.modelID) (~3.1 GB)…")
            let t0 = Date()
            try await qwen.load()
            print("✓ loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            let sentence = value(after: "--test-brain") ?? "mujhe 6 baje yaad dilana ki gym jaana hai"
            let t1 = Date()
            let command = try await qwen.plan(sentence)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            print("\"\(sentence)\" → \(String(data: try enc.encode(command?.steps ?? []), encoding: .utf8)!) in \(Int(Date().timeIntervalSince(t1) * 1000)) ms")
            exit(0)
        } catch {
            print("✗ \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
} else if args.contains("--vocabulary") {
    // Builds the custom speech vocabulary now and reports whether macOS accepted it.
    Task { @MainActor in
        let s = Settings.load()
        let contacts = ContactBook()
        await contacts.reload()
        let apps = Everyday.installedApps().values.map { $0.deletingPathExtension().lastPathComponent }
        let started = Date()
        let config = await CustomVocabulary.prepare(locale: Locale(identifier: s.speechLocale), names: contacts.spokenNames, apps: apps)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let config {
            print("✓ custom vocabulary ready in \(ms) ms: \(config.languageModel.path)")
            exit(0)
        }
        print("✗ custom vocabulary failed after \(ms) ms (see: log show --last 2m --predicate 'subsystem == \"dev.prgupta.bolo\"')")
        exit(1)
    }
    RunLoop.main.run()
} else if let text = value(after: "--remote") {
    // Runs a sentence inside the running Bolo.app, with its permissions, as if spoken.
    RemoteControl.send(text, dryRun: args.contains("--dry-run"))
    print("Sent to Bolo: \(text)\(args.contains("--dry-run") ? " (dry run)" : ""). Watch the notch, or:")
    print("  log show --last 1m --predicate 'subsystem == \"dev.prgupta.bolo\"' --style compact")
    exit(0)
} else if args.contains("--listen") {
    // Speak into the Mac and watch the live transcript, then see what Bolo would do. Nothing runs.
    //   Bolo --listen [seconds] [--no-noise]
    Task { @MainActor in
        var settings = Settings.load()
        if args.contains("--no-noise") { settings.noiseSuppression = false }
        let seconds = value(after: "--listen").flatMap(Double.init) ?? 5
        let contacts = ContactBook()
        await contacts.reload()
        let engine = SpeechEngine(settings: settings)
        engine.contextualStrings = contacts.spokenNames
        engine.onText = { text in
            print("\r\u{1B}[K  … \(text)", terminator: "")
            fflush(stdout)
        }
        print("Listening for \(Int(seconds)) s. Speak now.")
        do {
            try await engine.start()
        } catch {
            print("✗ microphone didn't start: \(error.localizedDescription)")
            exit(1)
        }
        try? await Task.sleep(for: .seconds(seconds))
        let heard = await engine.stop()
        print("\n")
        print("Mic:          \(engine.micDescription), \(engine.stats.buffers) buffers, peak level \(String(format: "%.2f", engine.stats.maxLevel))")
        print("Heard:        \(heard.text.isEmpty ? "(nothing)" : heard.text)")
        print("Confidence:   \(heard.confidence.map { String(format: "%.2f", $0) } ?? "n/a")")
        for (i, alt) in heard.alternatives.prefix(3).enumerated() { print("Alternative \(i + 1): \(alt)") }
        let apps = Everyday.installedApps()
        let parser = CommandParser(knownNames: contacts.spokenNames, knownApps: Set(apps.keys).union(AppNames.aliases.keys))
        if let (command, index) = parser.parse(candidates: heard.candidates) {
            let decision = SendPolicy.apply(command, confidence: heard.confidence, minConfidence: settings.minSendConfidence, usedAlternative: index > 0)
            print("Bolo would:   " + decision.command.steps.map(\.summary).joined(separator: "  →  "))
            if let reason = decision.reason { print("              (\(reason))") }
        } else if !heard.text.isEmpty {
            print("Bolo would:   ask Qwen (no phrase rule matched)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if args.contains("--doctor") {
    Task { @MainActor in
        print("Bolo setup check (permission lines describe the app you ran this from, e.g. Terminal;")
        print("use \"Check setup…\" in Bolo's menu for Bolo.app's own permissions)\n")
        for line in await SetupCheck.run() { print(line.rendered) }
        exit(0)
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
    let text = args[i + 1]
    let dryRun = args.contains("--dry-run")
    let useModel = !args.contains("--no-model")
    Task { @MainActor in
        let contacts = ContactBook()
        if !dryRun { await contacts.reload() }
        let apps = Everyday.installedApps()
        let parser = CommandParser(knownNames: contacts.spokenNames, knownApps: Set(apps.keys).union(AppNames.aliases.keys))
        let started = Date()
        var command = parser.parse(candidates: [text])?.command
        if command == nil, useModel { command = try? await ModelPlanner().plan(HearingFixes.apply(text)) }
        let ms = Int(Date().timeIntervalSince(started) * 1000)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let command else {
            print("No command understood in: \(text) (\(ms) ms)")
            exit(1)
        }
        print(String(data: try! enc.encode(command), encoding: .utf8)!)
        print("understood in \(ms) ms")
        if dryRun { exit(0) }

        let executor = Executor(settings: Settings.load(), contacts: contacts)
        for step in command.steps {
            do {
                print("✓", try await executor.run(step))
            } catch {
                print("✗", error.localizedDescription)
                exit(1)
            }
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
