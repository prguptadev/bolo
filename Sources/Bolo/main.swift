import AppKit
import BoloCore
import Foundation

// Bolo.app/Contents/MacOS/Bolo                       -> menu-bar app
// Bolo --say "open notes" [--dry-run] [--no-model]    -> run one command from the terminal
// Bolo --doctor                                       -> what this Mac still needs
// Bolo --batch prompts.jsonl [--names a,b] [--no-model] -> understand each {"id","say"} line, print JSONL (never acts)
let args = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let path = value(after: "--batch") {
    Task { @MainActor in
        struct Prompt: Decodable { let id: String; let say: String }
        struct Row: Encodable { let id: String; let source: String?; let steps: [Step]; let ms: Int }
        let names = value(after: "--names")?.split(separator: ",").map(String.init) ?? []
        let apps = Everyday.installedApps()
        let parser = CommandParser(knownNames: names, knownApps: Set(apps.keys).union(AppNames.aliases.keys))
        let planner = args.contains("--no-model") ? nil : try? ModelPlanner()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n") ?? []
        for line in lines {
            guard let p = try? JSONDecoder().decode(Prompt.self, from: Data(line.utf8)) else { continue }
            let started = Date()
            var command = parser.parse(p.say)
            if command == nil, let planner { command = try? await planner.plan(p.say) }
            let row = Row(id: p.id, source: command?.source.rawValue, steps: command?.steps ?? [], ms: Int(Date().timeIntervalSince(started) * 1000))
            print(String(data: try! enc.encode(row), encoding: .utf8)!)
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
        var command = parser.parse(text)
        if command == nil, useModel { command = try? await ModelPlanner().plan(text) }
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
