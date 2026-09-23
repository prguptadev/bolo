import AppKit
import BoloCore
import Foundation

/// Runs one agent action with the matching skill and returns a short line for the notch and the
/// next prompt. The permission check happens before this, in AgentLoop.
final class Tools {
    let settings: Settings
    let contacts: ContactBook
    let executor: Executor
    var qwen: QwenPlanner?
    var isCancelled: () -> Bool = { false }
    /// The terminal folder, carried between shell commands and conversations.
    var cwd: String

    init(settings: Settings, contacts: ContactBook, executor: Executor) {
        self.settings = settings
        self.contacts = contacts
        self.executor = executor
        cwd = FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// `goal` and `said` (everything said this conversation) ground contacts and message text.
    func run(_ a: AgentAction, seeing snap: Observer.Snapshot, goal: String, said: [String]) async throws -> String {
        switch a.tool {
        case .openApp:
            return try await Everyday.openApp(a.app ?? "", installed: executor.installedApps)

        case .openURL:
            var url = a.url ?? ""
            if !url.contains("://"), !url.contains("."), !url.hasPrefix("localhost") {
                // "open_url gmail": the model named a site, not an address. Let the browser search for it.
                url = "https://www.google.com/search?q=" + (url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url) + "&btnI=1"
            }
            if !url.lowercased().hasPrefix("http") { url = "https://" + url }
            // In the browser you're looking at, go there in this tab, like a person would.
            if let b = snap.browser ?? BrowserControl.browser(for: snap.bundleID) {
                do {
                    try await BrowserControl.navigate(to: url, in: b, newTab: a.newTab)
                    return "Opened \(url)\(a.newTab ? " in a new tab" : "")"
                } catch {
                    Log.agent.notice("tab navigation failed, opening normally: \(error.localizedDescription, privacy: .public)")
                }
            }
            return try Everyday.openURL(url)

        case .tab:
            guard let b = snap.browser ?? BrowserControl.browser(for: snap.bundleID) else { throw SkillError.failed("No browser is in front.") }
            try await BrowserControl.selectTab(a.id ?? 1, in: b)
            return "Switched to tab \(a.id ?? 1)"

        case .openFile:
            let path = expand(a.path ?? "")
            guard FileManager.default.fileExists(atPath: path) else { throw SkillError.failed("No file at \(path).") }
            if let app = a.app, !app.isEmpty {
                let key = app.lowercased()
                let appURL = executor.installedApps[key] ?? executor.installedApps.first { $0.key.hasPrefix(key) || $0.key.contains(key) }?.value
                guard let appURL else { throw SkillError.failed("Couldn't find an app called \(app).") }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                try await NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)
                return "Opened \((path as NSString).lastPathComponent) in \(appURL.deletingPathExtension().lastPathComponent)"
            }
            guard NSWorkspace.shared.open(URL(fileURLWithPath: path)) else { throw SkillError.failed("Couldn't open \(path).") }
            return "Opened \((path as NSString).lastPathComponent)"

        case .click:
            if let id = a.id {
                if let b = snap.browser { return try await BrowserControl.click(id: id, in: b) }
                guard let el = snap.elements[id] else { throw SkillError.failed(noSuchID(id, snap)) }
                guard ScreenControl.press(el) else { throw SkillError.failed("Couldn't press [\(id)].") }
                return "Clicked \(snap.label(of: id).map { "\"\($0)\"" } ?? "[\(id)]")"
            }
            let label = a.label ?? ""
            if let b = snap.browser, let r = try? await BrowserControl.click(label: label, in: b) { return r }
            return try ScreenControl.click(label)

        case .fill:
            var text = a.text ?? ""
            // "pr.gupta 1993@gmail.com" was dictated: an address has no spaces.
            if text.contains("@"), text.range(of: "^[\\w.+\\- ]+@[\\w.\\- ]+$", options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: " ", with: "")
            }
            if let id = a.id {
                if let b = snap.browser { return try await BrowserControl.fill(id: id, text: text, in: b) }
                guard let el = snap.elements[id] else { throw SkillError.failed(noSuchID(id, snap)) }
                if snap.role(of: id) == "password field" { throw SkillError.failed("That's a password field. Bolo never types passwords.") }
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) != .success {
                    ScreenControl.press(el)
                    try await Task.sleep(for: .milliseconds(150))
                    _ = try ScreenControl.pressKey("cmd+a")
                    await MacControl.paste(text)
                }
                return "Filled \(snap.label(of: id).map { "\"\($0)\"" } ?? "[\(id)]")"
            }
            return try await ScreenControl.typeInto(a.label ?? "", text: text)

        case .type:
            let text = a.text ?? ""
            if let front = MacControl.frontmostBundleID(), AppHints.chatApps.contains(front) {
                throw SkillError.failed("Won't type into an open chat. Use the message tool with the person's name.")
            }
            await MacControl.paste(text)
            return "Typed \(text.count) characters"

        case .key:
            return try ScreenControl.pressKey(normalizeKeys(a.keys ?? ""))

        case .menu:
            let label = a.label ?? ""
            do {
                return try ScreenControl.menu(label)
            } catch {
                // Tell the model what that menu really holds, so it stops guessing item names.
                let top = label.components(separatedBy: CharacterSet(charactersIn: ">›")).first?.trimmingCharacters(in: .whitespaces) ?? ""
                if let front = try? ScreenControl.front() {
                    let items = ScreenControl.menuItems(front.element).filter { $0.path.count == 2 && $0.path[0].lowercased() == top.lowercased() }.map(\.title)
                    if !items.isEmpty { throw SkillError.failed("\(error.localizedDescription) The \(top) menu has: \(items.prefix(25).joined(separator: ", ")).") }
                    let menus = ScreenControl.menuItems(front.element).map { $0.path[0] }
                    let names = Array(NSOrderedSet(array: menus)) as? [String] ?? []
                    throw SkillError.failed("\(error.localizedDescription) Menus: \(names.joined(separator: ", ")).")
                }
                throw error
            }

        case .scroll:
            let dir = a.direction ?? "down"
            if let b = snap.browser { return try await BrowserControl.scroll(dir, in: b) }
            return try ScreenControl.scroll(dir, pages: 1)

        case .wait:
            let s = min(max(a.seconds ?? 1.5, 0.2), 8)
            try await Task.sleep(for: .seconds(s))
            return "Waited \(String(format: "%.0f", s)) s"

        case .shell:
            return try await shell(a.command ?? "")

        case .listFiles:
            let path = expand(a.path ?? cwd)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw SkillError.failed("No folder at \(path).") }
            let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted { $0.lowercased() < $1.lowercased() }
            let lines = names.prefix(80).map { name -> String in
                var d: ObjCBool = false
                FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &d)
                return d.boolValue ? name + "/" : name
            }
            cwd = path
            return "\(path): " + (lines.isEmpty ? "(empty)" : lines.joined(separator: ", ")) + (names.count > 80 ? " … and \(names.count - 80) more" : "")

        case .readFile:
            let path = expand(a.path ?? "")
            guard let data = FileManager.default.contents(atPath: path) else { throw SkillError.failed("Couldn't read \(path).") }
            let text = String(decoding: data.prefix(6000), as: UTF8.self)
            return "\((path as NSString).lastPathComponent) (\(data.count) bytes):\n" + text + (data.count > 6000 ? "\n…" : "")

        case .writeFile:
            let path = expand(a.path ?? "")
            let folder = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try (a.text ?? "").write(toFile: path, atomically: true, encoding: .utf8)
            cwd = folder
            return "Wrote \((path as NSString).lastPathComponent) (\((a.text ?? "").count) characters) in \(folder)"

        case .message, .call:
            // The person must have been named by the user; the words are sent only if the user said
            // them (a message the model wrote is typed as a draft, never sent).
            let who = a.contact ?? ""
            let everything = ([goal] + said).joined(separator: " ")
            // Spoken, or a sound-alike of something spoken ("Aku" for "Akku"); never a name off the screen.
            let spokenWords = Grounding.words(everything)
            let named = Grounding.share(of: who, in: everything) == 1
                || Grounding.words(who).allSatisfy { w in spokenWords.contains { Fuzzy.soundKey($0) == Fuzzy.soundKey(w) } }
            guard named else { throw SkillError.failed("You didn't name \(who). Say who it's for.") }
            let channel = a.app.flatMap(Channel.from(spoken:))
            if a.tool == .call { return try await executor.run(Step(.call, contact: who, channel: channel ?? .teams)) }
            let text = a.text ?? ""
            let sendVerb = goal.range(of: "\\b(send|message|text|tell|bhejo|bhej do|bol do|bolo|batao|karo)\\b", options: [.regularExpression, .caseInsensitive]) != nil
            let send = sendVerb && Grounding.share(of: text, in: everything) >= 0.8
            return try await executor.run(Step(send ? .sendMessage : .draftMessage, contact: who, channel: channel, text: text, generated: send ? nil : true))

        case .note:
            return try await Everyday.newNote(a.text ?? "")

        case .reminder:
            return try await Everyday.addReminder(a.text ?? "", time: a.time)

        case .system:
            guard let op = SystemOp(rawValue: a.op ?? "") else { throw SkillError.failed("Unknown system action \(a.op ?? "").") }
            return try await SystemSkills.run(op, app: a.app, text: a.text, installed: executor.installedApps)

        case .remember:
            try Memory.add(a.text ?? "")
            return "Remembered: \(a.text ?? "")"

        case .lookup:
            return try await executor.run(Step(.lookup, text: a.text))

        case .done, .ask:
            return a.text ?? ""
        }
    }

    // MARK: Terminal

    /// Runs in zsh (your profile loaded), in the carried folder, with the output trimmed to what the
    /// model needs. `cd` carries over to the next command.
    func shell(_ command: String, timeout: Double = 60) async throws -> String {
        let marker = "__BOLO_CWD__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command + "\n__bolo_status=$?; printf '\\n\(marker)%s\\n' \"$PWD\"; exit $__bolo_status"]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        let collected = LockedText()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { collected.append(String(decoding: d, as: UTF8.self)) }
        }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if isCancelled() || Date() > deadline {
                p.terminate()
                throw SkillError.failed(isCancelled() ? "Stopped." : "`\(Conversation.short(command, 40))` took more than \(Int(timeout)) s and was stopped.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        out.fileHandleForReading.readabilityHandler = nil
        var text = collected.value
        if let r = text.range(of: marker) {
            let newCwd = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !newCwd.isEmpty { cwd = newCwd }
            text = String(text[..<r.lowerBound])
        }
        text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = p.terminationStatus
        let shown = text.count > 3000 ? String(text.prefix(1500)) + "\n…\n" + String(text.suffix(1200)) : text
        if status != 0 { return "exit \(status)" + (shown.isEmpty ? "" : ": " + shown) }
        return shown.isEmpty ? "Done (no output)" : shown
    }

    private func noSuchID(_ id: Int, _ snap: Observer.Snapshot) -> String {
        let n = snap.observation.elements.count
        return n == 0 ? "The screen list is empty, so there's no [\(id)]. Use a menu, a key or open_url." : "There's no [\(id)]; the list has 1–\(n). Look again."
    }

    private func expand(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? p : cwd + "/" + p
    }

    /// "Cmd+Shift+O", "⌘S", "command+n", "enter" → what ScreenControl.pressKey understands.
    private func normalizeKeys(_ keys: String) -> String {
        var k = keys.lowercased().replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "⌘", with: "cmd+").replacingOccurrences(of: "⇧", with: "shift+")
            .replacingOccurrences(of: "⌥", with: "opt+").replacingOccurrences(of: "⌃", with: "ctrl+")
            .replacingOccurrences(of: "command", with: "cmd").replacingOccurrences(of: "option", with: "opt").replacingOccurrences(of: "alt", with: "opt")
            .replacingOccurrences(of: "control", with: "ctrl").replacingOccurrences(of: "enter", with: "return")
            .replacingOccurrences(of: "esc+", with: "escape+").replacingOccurrences(of: "backspace", with: "delete")
            .replacingOccurrences(of: "-", with: "+")
        if k == "esc" { k = "escape" }
        if k.hasSuffix("++") { k = String(k.dropLast()) }  // "cmd++" for cmd and "+"
        return k
    }
}

/// Output collected from a running process, read from its pipe's background thread.
final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func append(_ s: String) {
        lock.withLock {
            text += s
            if text.count > 60_000 { text = String(text.suffix(40_000)) }
        }
    }
}
