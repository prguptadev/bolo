import BoloCore
import Foundation

/// Things you told Bolo to remember, one per line, in
/// ~/Library/Application Support/Bolo/memory.md. Given to the agent on every task.
enum Memory {
    static let url = Settings.folder.appendingPathComponent("memory.md")

    static func read() -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.suffix(40).joined(separator: "\n")
    }

    static func add(_ fact: String) throws {
        let line = "- " + fact.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try handle.close()
        } else {
            try ("# What Bolo remembers (edit freely)\n" + line).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Your own tips for an app, like OpenWork skills: a Markdown file per app in
/// ~/Library/Application Support/Bolo/skills/, named after the app ("IntelliJ IDEA.md") or its
/// bundle id ("com.jetbrains.intellij.md"). Added to the built-in tips when that app is in front.
enum Skills {
    static let folder = Settings.folder.appendingPathComponent("skills", isDirectory: true)

    static func hints(app: String, bundleID: String?) -> String? {
        let builtIn = AppHints.hints(bundleID: bundleID, app: app)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = [app, bundleID ?? ""].filter { !$0.isEmpty }
        let mine = names.compactMap { name -> String? in
            let text = try? String(contentsOf: folder.appendingPathComponent(name + ".md"), encoding: .utf8)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { Conversation.short($0, 1500) }
        }.first
        return [builtIn, mine].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
    }
}
