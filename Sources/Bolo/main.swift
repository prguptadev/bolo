import AppKit
import BoloCore
import Foundation

// Bolo.app/Contents/MacOS/Bolo                       -> menu-bar app
// Bolo --say "open notes" [--dry-run] [--no-model]    -> run one command from the terminal
let args = CommandLine.arguments

if let i = args.firstIndex(of: "--say"), i + 1 < args.count {
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
