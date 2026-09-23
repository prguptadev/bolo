import Foundation

// The agent loop: look at the screen, pick one action, do it, look again, until the goal is done.
// Ideas taken from open-source agents:
// - Peekaboo and browser-use: number what's on screen so the model points at "[12]", not pixels.
// - Microsoft UFO: prefer a direct action (write the file, open the URL) over clicking through UI.
// - opencode and OpenWork: every tool has a risk; your permission level decides allow / ask / deny.

/// One thing on screen the agent can point at by number.
public struct ScreenElement: Sendable, Equatable {
    public let id: Int
    public let role: String
    public let label: String
    public let value: String?

    public init(id: Int, role: String, label: String, value: String? = nil) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
    }
}

/// What the agent sees each turn: the app in front, its window, and its numbered elements.
public struct Observation: Sendable {
    public var app: String
    public var bundleID: String?
    public var window: String?
    public var url: String?
    /// The file open in the front window, when the app says (JetBrains, Xcode, TextEdit…).
    public var document: String?
    public var focused: String?
    public var menus: [String] = []
    public var elements: [ScreenElement] = []
    /// Elements that didn't fit in the list.
    public var hidden = 0
    /// Something the agent should know, like "this page can't be read".
    public var note: String?
    /// macOS itself is asking the user something (a permission prompt): the agent must stop.
    public var systemDialog = false
    /// Plain text on the page or window, for context and for reading tasks.
    public var text: String?

    public init(app: String) {
        self.app = app
    }

    /// What the model would act on. When this is the same as last step's, the screen isn't resent
    /// (text that jitters, like a clock or a chat, doesn't count).
    public var signature: String {
        ([app, window ?? "", url ?? "", focused ?? ""] + elements.map { "\($0.id)|\($0.role)|\($0.label)|\($0.value ?? "")" }).joined(separator: "\n")
    }

    /// Compact on purpose: every bracket and quote is a token, and the model reads this each step.
    /// `menus` are only worth sending when the app changed.
    public func render(includeMenus: Bool = true) -> String {
        var lines = ["App: \(app)"]
        if let window { lines.append("Window: \(Conversation.short(window, 100))") }
        if let url { lines.append("Page: \(Conversation.short(url, 140))") }
        if let document { lines.append("Open file: \(document)") }
        if let focused { lines.append("Focused: \(Conversation.short(focused, 120))") }
        if includeMenus, !menus.isEmpty { lines.append("Menus: " + menus.joined(separator: ", ")) }
        if let note { lines.append("Note: \(note)") }
        if elements.isEmpty {
            lines.append("Screen: nothing readable in this window.")
        } else {
            lines.append("Screen (id kind label):")
            for e in elements {
                var line = "\(e.id) \(e.role) \(Conversation.short(e.label, 60))"
                if let v = e.value, !v.isEmpty, v != e.label { line += " = \(Conversation.short(v, 50))" }
                lines.append(line)
            }
            if hidden > 0 { lines.append("(\(hidden) more not listed: scroll, or use a menu or shortcut)") }
        }
        if let text, !text.isEmpty { lines.append("Text on screen: \(text)") }
        return lines.joined(separator: "\n")
    }
}

/// One step the model chose.
public struct AgentAction: Sendable, Equatable {
    public enum Tool: String, Sendable, CaseIterable {
        case openApp = "open_app", openURL = "open_url", openFile = "open_file"
        case click, fill, type, key, menu, scroll, wait, tab
        case shell, listFiles = "list_files", readFile = "read_file", writeFile = "write_file"
        case message, call, note, reminder, system, remember, lookup, done, ask
    }

    public var tool: Tool
    public var thought: String?
    public var id: Int?
    /// A button or menu label ("Save", "File > New"), when there's no id.
    public var label: String?
    /// Typed text, file content, message, query, answer or question.
    public var text: String?
    public var app: String?
    public var url: String?
    public var path: String?
    public var keys: String?
    public var command: String?
    public var contact: String?
    public var direction: String?
    public var seconds: Double?
    /// A reminder's time ("at 5 pm", "tomorrow 9am").
    public var time: String?
    /// A SystemOp name for the system tool ("emptyTrash", "quitApp", "darkModeOn"…).
    public var op: String?
    /// The model says this action finishes the goal: don't ask it again afterwards.
    public var last = false
    /// open_url: in a new browser tab instead of the one in front.
    public var newTab = false

    /// Same action, whatever the model was thinking: repeating it won't help.
    public static func == (a: AgentAction, b: AgentAction) -> Bool {
        a.tool == b.tool && a.id == b.id && a.label == b.label && a.text == b.text && a.app == b.app && a.url == b.url
            && a.path == b.path && a.keys == b.keys && a.command == b.command && a.contact == b.contact
            && a.direction == b.direction && a.time == b.time && a.op == b.op && a.newTab == b.newTab
    }

    public init(_ tool: Tool, id: Int? = nil, label: String? = nil, text: String? = nil, app: String? = nil, url: String? = nil,
                path: String? = nil, keys: String? = nil, command: String? = nil, contact: String? = nil) {
        self.tool = tool
        self.id = id
        self.label = label
        self.text = text
        self.app = app
        self.url = url
        self.path = path
        self.keys = keys
        self.command = command
        self.contact = contact
    }

    public var isFinal: Bool { tool == .done || tool == .ask }

    // MARK: Reading the model's reply

    private static let toolAliases: [String: Tool] = [
        "openapp": .openApp, "launch": .openApp, "launch_app": .openApp, "activate": .openApp, "switch_app": .openApp,
        "openurl": .openURL, "navigate": .openURL, "go_to": .openURL, "goto": .openURL, "open_website": .openURL, "browse": .openURL,
        "openfile": .openFile, "open": .openFile,
        "tap": .click, "press_button": .click, "click_element": .click,
        "set_value": .fill, "type_into": .fill, "input": .fill, "enter_text": .fill, "fill_field": .fill,
        "type_text": .type, "write_text": .type, "paste": .type,
        "press": .key, "press_key": .key, "hotkey": .key, "shortcut": .key, "keys": .key,
        "menu_click": .menu, "choose_menu": .menu, "switch_tab": .tab, "select_tab": .tab, "goto_tab": .tab, "go_to_tab": .tab, "activate_tab": .tab,
        "sleep": .wait, "pause": .wait,
        "bash": .shell, "terminal": .shell, "run": .shell, "run_command": .shell, "exec": .shell, "command": .shell,
        "ls": .listFiles, "list": .listFiles, "list_dir": .listFiles, "read": .readFile, "cat": .readFile,
        "create_file": .writeFile, "write": .writeFile, "new_file": .writeFile, "save_file": .writeFile,
        "send_message": .message, "send": .message, "chat": .message, "phone": .call, "call_contact": .call,
        "new_note": .note, "make_note": .note, "add_reminder": .reminder, "remind": .reminder, "set_reminder": .reminder,
        "system_op": .system, "mac": .system, "memory": .remember, "save_memory": .remember,
        "search": .lookup, "web_search": .lookup,
        "finish": .done, "answer": .done, "complete": .done, "reply": .done, "stop": .done, "final": .done,
        "question": .ask, "ask_user": .ask, "clarify": .ask,
    ]

    /// The first JSON object in the reply (models sometimes add fences or chatter), read leniently.
    public static func parse(_ reply: String) -> AgentAction? {
        guard let json = firstJSONObject(in: reply),
            let data = json.data(using: .utf8),
            var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // {"tool":"click","args":{"id":3}} and {"action":{"name":"click","id":3}}
        for key in ["args", "arguments", "parameters", "params", "input"] {
            if let inner = dict[key] as? [String: Any] { dict.merge(inner) { a, _ in a } }
        }
        if let inner = dict["action"] as? [String: Any] {
            dict.merge(inner) { a, _ in a }
            dict["action"] = inner["name"] ?? inner["tool"]
        }
        func str(_ keys: String...) -> String? {
            for k in keys {
                if let s = dict[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
                if let n = dict[k] as? NSNumber { return n.stringValue }
            }
            return nil
        }
        guard let rawTool = str("tool", "action", "name", "type_of_action") else { return nil }
        let name = snake(rawTool)
        guard let tool = Tool(rawValue: name) ?? toolAliases[name] ?? toolAliases[name.replacingOccurrences(of: "_", with: "")] else { return nil }

        var a = AgentAction(tool)
        a.thought = str("thought", "reason", "thinking", "why", "plan")
        if let n = dict["id"] as? NSNumber {
            a.id = n.intValue
        } else if let s = str("id", "element", "element_id", "index") {
            a.id = Int(s.filter(\.isNumber))
            if a.id == nil, tool == .click { a.label = s }
        }
        a.label = a.label ?? str("label", "target", "title", "menu", "button", "item", "element_label")
        a.text = str("text", "content", "value", "message", "query", "answer", "summary", "question", "code", "body")
        a.app = str("app", "application", "app_name", "with")
        a.url = str("url", "address", "link", "href")
        a.path = str("path", "file", "filename", "file_path", "folder", "directory", "dir")
        a.keys = str("keys", "key", "combo", "shortcut", "hotkey")
        a.command = str("command", "cmd", "script")
        a.contact = str("contact", "to", "person", "recipient")
        a.direction = str("direction", "dir_scroll")?.lowercased()
        a.seconds = (dict["seconds"] as? NSNumber)?.doubleValue ?? (dict["duration"] as? NSNumber)?.doubleValue
        a.time = str("time", "when", "at")
        a.op = str("op", "operation", "system_action")
        a.last = ["last", "final_step", "finish", "done", "then_done"].contains { (dict[$0] as? Bool) == true }
        a.newTab = ["new_tab", "newTab", "new_window"].contains { (dict[$0] as? Bool) == true }
        if a.id == nil, tool == .tab, let s = str("tab", "number", "n") { a.id = Int(s.filter(\.isNumber)) }

        // Fill in the obvious field from the generic one.
        switch tool {
        case .openApp: a.app = a.app ?? a.label ?? a.text
        case .openURL: a.url = a.url ?? a.text
        case .key: a.keys = a.keys ?? a.text
        case .menu: a.label = a.label ?? a.path ?? a.text
        case .shell: a.command = a.command ?? a.text
        case .scroll: a.direction = a.direction ?? a.text?.lowercased() ?? "down"
        case .lookup: a.text = a.text ?? a.label
        case .system: a.op = a.op ?? a.label ?? a.text
        case .call: a.contact = a.contact ?? a.label
        default: break
        }
        return a.isComplete ? a : nil
    }

    /// Has what its tool needs.
    public var isComplete: Bool {
        func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch tool {
        case .openApp: return has(app)
        case .openURL: return has(url)
        case .openFile, .readFile, .listFiles: return has(path) || tool == .listFiles
        case .click: return id != nil || has(label)
        case .fill: return (id != nil || has(label)) && text != nil
        case .type: return text != nil && !(text ?? "").isEmpty
        case .key: return has(keys)
        case .menu: return has(label)
        case .scroll, .wait: return true
        case .tab: return id != nil
        case .shell: return has(command)
        case .writeFile: return has(path) && text != nil
        case .message: return has(contact) && has(text)
        case .call: return has(contact)
        case .note, .reminder, .remember: return has(text)
        case .system: return SystemOp(rawValue: op ?? "") != nil
        case .lookup: return has(text)
        case .done, .ask: return true
        }
    }

    static func snake(_ s: String) -> String {
        var out = ""
        for ch in s.trimmingCharacters(in: .whitespaces) {
            if ch.isUppercase, !out.isEmpty, out.last != "_" { out.append("_") }
            out.append(contentsOf: ch.lowercased())
        }
        return out.replacingOccurrences(of: "[ -]+", with: "_", options: .regularExpression)
    }

    /// Scans for a balanced {...}, ignoring braces inside strings (file contents are full of them).
    public static func firstJSONObject(in s: String) -> String? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                var depth = 0, inString = false, escaped = false
                var j = i
                while j < chars.count {
                    let c = chars[j]
                    if inString {
                        if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    } else if c == "\"" {
                        inString = true
                    } else if c == "{" {
                        depth += 1
                    } else if c == "}" {
                        depth -= 1
                        if depth == 0 { return String(chars[i...j]) }
                    }
                    j += 1
                }
                return nil
            }
            i += 1
        }
        return nil
    }

    // MARK: For the notch

    public var summary: String {
        func q(_ s: String?, _ n: Int = 40) -> String { "\"\(Conversation.short(s ?? "", n))\"" }
        switch tool {
        case .openApp: return "Open \(app ?? "")"
        case .openURL: return "Go to \(URL(string: url ?? "")?.host ?? url ?? "")"
        case .openFile: return "Open \((path as NSString?)?.lastPathComponent ?? "")\(app.map { " in \($0)" } ?? "")"
        case .click: return "Click \(label.map { q($0) } ?? "#\(id ?? 0)")"
        case .fill: return "Fill \(label.map { q($0, 30) } ?? "#\(id ?? 0)") with \(q(text, 30))"
        case .type: return "Type \(q(text))"
        case .key: return "Press \(KeyCombo.canonical(keys ?? "") ?? keys ?? "")"
        case .menu: return "Menu \(label?.replacingOccurrences(of: ">", with: "›") ?? "")"
        case .scroll: return "Scroll \(direction ?? "down")"
        case .tab: return "Tab \(id ?? 0)"
        case .wait: return "Wait"
        case .shell: return "Run `\(Conversation.short(command ?? "", 60))`"
        case .listFiles: return "List \(path ?? "folder")"
        case .readFile: return "Read \((path as NSString?)?.lastPathComponent ?? "")"
        case .writeFile: return "Write \((path as NSString?)?.lastPathComponent ?? "")"
        case .message: return "Message \(contact ?? "") \(q(text, 30))"
        case .call: return "Call \(contact ?? "")"
        case .note: return "Note \(q(text))"
        case .reminder: return "Remind \(q(text))\(time.map { " " + $0 } ?? "")"
        case .system: return SystemOp(rawValue: op ?? "")?.summary(app: app, text: text) ?? (op ?? "")
        case .remember: return "Remember \(q(text))"
        case .lookup: return "Look up \(q(text))"
        case .done: return text ?? "Done"
        case .ask: return text ?? "Need more detail"
        }
    }

    // MARK: Risk

    private static let sendWords = "send|submit|post|publish|reply|reply all|forward|tweet|share|comment|confirm|approve|accept|invite|schedule send"
    private static let destroyWords = "delete|remove|discard|trash|erase|empty|uninstall|clear all|deactivate|revoke|archive all|unsubscribe|leave group|block"
    private static let moneyWords = "pay|payment|buy|buy now|purchase|place order|checkout|check out|proceed to pay|transfer|send money|donate|upi"

    private static func words(_ s: String?, match pattern: String) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return s.range(of: "\\b(?:" + pattern + ")\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Buttons of permission prompts, macOS's ("Bolo would like to control Chrome") or a browser's
    /// ("wikipedia.org wants to show notifications"). Those answers are yours.
    private static let permissionButtons = "^(allow|block|don'?t allow|don’t allow|always allow|allow once|allow this time|allow on every visit|only while using|open system settings|not now|later|never|turn on|grant|ok, got it)$"

    public static func isPermissionButton(_ label: String?) -> Bool {
        guard let label else { return false }
        return label.trimmingCharacters(in: .whitespaces).range(of: permissionButtons, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Never done by Bolo, at any permission level. `elementLabel`/`elementRole`: what the id on
    /// the screen list points at (a click by number has no label of its own).
    public func forbidden(elementLabel: String? = nil, elementRole: String? = nil) -> String? {
        let what = label ?? elementLabel
        switch tool {
        case .click, .menu:
            if Self.isPermissionButton(what) { return "That's a permission prompt. The user answers those." }
            return Self.words(what, match: Self.moneyWords) ? "Bolo doesn't pay or buy. Do that yourself." : nil
        case .fill, .type:
            let secret = (elementRole ?? "").contains("password") || Self.words(what, match: "password|passcode|otp|cvv|card number|pin")
            return secret ? "Bolo never types passwords, codes or card numbers." : nil
        case .shell:
            return ShellSafety.forbidden(command ?? "")
        default:
            return nil
        }
    }

    /// How much this step changes. `inChatApp`: Return in a chat app sends. `elementLabel`: what a
    /// click by number points at.
    public func risk(inChatApp: Bool = false, elementLabel: String? = nil) -> Risk {
        let label = label ?? elementLabel
        switch tool {
        case .done, .ask, .wait, .readFile, .listFiles, .lookup: return .read
        case .openApp, .openURL, .openFile, .scroll, .tab: return .navigate
        case .note, .reminder, .remember: return .write
        case .call: return .send
        case .system: return Step(.system, app: app, text: text, target: op).risk
        case .click, .menu:
            if Self.words(label, match: Self.destroyWords) { return .destructive }
            if Self.words(label, match: Self.sendWords) { return .send }
            if tool == .menu, Self.words(label, match: "quit|close|log out|restart|shut down") { return .system }
            return .navigate
        case .key:
            // Compare on plain words: "cmd+q", "Cmd-Q", "⌘Q" and "command q" all mean quit.
            let k = (keys ?? "").lowercased()
                .replacingOccurrences(of: "⌘", with: "cmd ").replacingOccurrences(of: "command", with: "cmd")
                .replacingOccurrences(of: "[+\\-]", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let parts = Set(k.split(separator: " ").map(String.init))
            if parts.contains("cmd"), parts.contains("q") { return .system }
            if parts.contains("cmd"), parts.contains("delete") || parts.contains("backspace") || k.contains("⌫") { return .destructive }
            if inChatApp, parts.contains("return") || parts.contains("enter") || k.contains("↩") { return .send }
            return .navigate
        case .type, .fill, .writeFile: return .write
        case .shell: return ShellSafety.risk(command ?? "")
        case .message: return .send
        }
    }
}

/// Classifies terminal commands. Read-only ones run freely; deleting and overwriting need your OK;
/// a few are never run.
public enum ShellSafety {
    public static func forbidden(_ command: String) -> String? {
        let c = " " + command.lowercased() + " "
        let rules: [(String, String)] = [
            ("(^|[;&|\\s])(sudo|su|doas)\\s", "Bolo doesn't run commands as administrator. Run it yourself."),
            ("rm\\s+(-[a-z]*\\s+)*(/|~|\\$home|/\\*|~/\\*)(\\s|$)", "That would delete everything in a top folder."),
            ("(^|\\s)(mkfs|fdisk)\\b|\\bdd\\s.*of=/dev/|>\\s*/dev/(disk|rdisk)|diskutil\\s+(erase|partition|zero)", "Bolo doesn't touch disks."),
            (":\\(\\)\\s*\\{", "That's a fork bomb."),
            ("(curl|wget)\\s[^|]*\\|\\s*(sudo\\s+)?(ba|z)?sh\\b", "Bolo doesn't run scripts straight from the internet."),
            ("(^|[;&|\\s])(shutdown|reboot|halt)\\s", "Use \"restart the Mac\" or \"shut down\" instead."),
            ("security\\s+(dump-keychain|find-(generic|internet)-password\\s.*-w)", "Bolo doesn't read passwords."),
            ("csrutil|spctl\\s+--master-disable|nvram\\s", "Bolo doesn't change security settings."),
        ]
        for (pattern, reason) in rules where c.range(of: pattern, options: .regularExpression) != nil {
            return reason
        }
        return nil
    }

    private static let readOnly: Set<String> = [
        "ls", "pwd", "cat", "head", "tail", "less", "more", "wc", "grep", "rg", "egrep", "which", "whereis", "echo", "printf",
        "date", "cal", "df", "du", "file", "stat", "tree", "ps", "uptime", "whoami", "env", "printenv", "sw_vers", "uname",
        "mdfind", "mdls", "cd", "sort", "uniq", "cut", "jq", "man", "history", "diff", "cmp", "basename", "dirname", "realpath",
        "ifconfig", "ping", "host", "dig", "nslookup", "curl", "top", "lsof", "id", "hostname", "system_profiler", "pmset",
        "type", "command", "true", "test", "[", "column", "tr", "nl", "md5", "shasum", "open", "pbpaste", "say", "sleep",
    ]
    private static let destructive: Set<String> = [
        "rm", "rmdir", "srm", "shred", "kill", "killall", "pkill", "launchctl", "truncate", "chown", "unlink",
    ]

    public static func risk(_ command: String) -> Risk {
        var worst = Risk.read
        // Overwriting a file with ">" (">>" appends, "2>" and ">/dev/null" are harmless).
        let noHarmless = command.replacingOccurrences(of: "\\d?>\\s*/dev/null|2>&1|>>", with: " ", options: .regularExpression)
        if noHarmless.range(of: "(^|[^0-9&])>", options: .regularExpression) != nil { worst = .destructive }
        let segments = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments where !segment.isEmpty {
            var words = segment.split(separator: " ").map(String.init)
            while let w = words.first, w.contains("="), !w.hasPrefix("-") { words.removeFirst() }  // FOO=bar cmd
            guard let first = words.first.map({ ($0 as NSString).lastPathComponent.lowercased() }) else { continue }
            let rest = words.dropFirst().joined(separator: " ").lowercased()
            let r: Risk
            if destructive.contains(first) {
                r = .destructive
            } else if first == "git" {
                if rest.range(of: "^(reset --hard|clean|push\\s.*(--force|-f\\b)|branch -d|checkout -- |restore|stash drop|rebase)", options: .regularExpression) != nil {
                    r = .destructive
                } else if rest.range(of: "^(status|log|diff|show|branch$|branch -a|branch -v|remote|config --get|rev-parse|ls-files|blame)", options: .regularExpression) != nil {
                    r = .read
                } else {
                    r = .system
                }
            } else if first == "find" {
                r = rest.contains("-delete") || rest.range(of: "-exec\\s+rm", options: .regularExpression) != nil ? .destructive : .read
            } else if first == "sed" {
                r = rest.range(of: "(^|\\s)-i", options: .regularExpression) != nil ? .destructive : .read
            } else if first == "defaults" {
                r = rest.hasPrefix("read") ? .read : .destructive
            } else if first == "chmod" {
                r = rest.contains("-r") ? .destructive : .system
            } else if first == "curl" {
                r = rest.range(of: "(-o|--output|-x\\s*(post|put|delete)|-d\\s|--data)", options: .regularExpression) != nil ? .system : .read
            } else if readOnly.contains(first) {
                r = .read
            } else {
                r = .system
            }
            worst = max(worst, r)
        }
        return worst
    }
}

/// allow / ask / deny, like opencode's permission rules, set by your permission level.
public enum Verdict: Equatable, Sendable {
    case allow
    /// Say "yes" (hold the key) within a few seconds.
    case confirm
    /// Runs after a countdown in the notch; Esc stops it.
    case countdown
    case deny(String)
}

public enum AgentPolicy {
    public static func verdict(_ risk: Risk, level: PermissionLevel) -> Verdict {
        switch level {
        case .safe:
            return risk <= .write ? .allow : .deny("That needs the Standard permission level (menu bar › Settings, \"permissionLevel\").")
        case .standard:
            switch risk {
            case .read, .navigate, .write, .system: return .allow
            case .send, .destructive: return .confirm
            }
        case .full:
            return risk == .destructive ? .countdown : .allow
        }
    }
}

/// App know-how the agent gets when that app is in front (OpenWork calls these skills). Your own
/// notes in ~/Library/Application Support/Bolo/skills/<App name>.md are added after these.
public enum AppHints {
    public static let browsers: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.apple.Safari", "org.mozilla.firefox", "com.operasoftware.Opera",
    ]
    /// Code editors and IDEs: code goes in through files, never typed line by line.
    public static let editors: [String] = [
        "com.jetbrains.", "com.google.android.studio", "com.microsoft.VSCode", "com.apple.dt.Xcode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.", "com.github.atom", "com.panic.Nova", "com.barebones.bbedit", "org.vim.MacVim",
    ]
    public static func isEditor(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return editors.contains { bundleID.hasPrefix($0) }
    }

    public static let chatApps: Set<String> = [
        "net.whatsapp.WhatsApp", "com.microsoft.teams2", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
        "com.hnc.Discord",
    ]

    public static func hints(bundleID: String?, app: String) -> String? {
        let id = bundleID ?? ""
        if id.hasPrefix("com.jetbrains.") || id == "com.google.android.studio" {
            return """
                \(app) (JetBrains IDE). The window title is "project – file". "Open file" shows the file in the editor; the project folder \
                is the part of that path up to the project's name. To make a new file with code: write_file inside the project \
                (next to the open file, or under src/…), then open_file with app "\(app)". Go to a file: key cmd+shift+o, type its \
                name, key return. Find any action: key cmd+shift+a. Files save by themselves.
                """
        }
        if id == "com.microsoft.VSCode" {
            return "VS Code. New file with code: write_file, then open_file with app \"Visual Studio Code\". Open a file: key cmd+p, type the name, return. Commands: key cmd+shift+p."
        }
        if id == "com.apple.dt.Xcode" {
            return "Xcode. Open a file: key cmd+shift+o, type the name, return. Build: cmd+b. Run: cmd+r. New file with code: write_file into the project folder, then open_file."
        }
        if browsers.contains(id) {
            return """
                Web browser. Go to a site: open_url with its address (same tab). The screen list is the page's links, buttons, \
                tabs and fields: click and fill them by id; a site's search box is a field in that list. Web search only when \
                asked: open_url https://www.google.com/search?q=… . Other tabs: the tab tool. Back: key cmd+[. Close tab: key cmd+w.
                """
        }
        if id == "com.apple.Terminal" || id == "com.googlecode.iterm2" {
            return "Terminal is open, but you don't need it: the shell tool runs commands and returns their output."
        }
        if id == "com.apple.finder" {
            return "Finder. Prefer list_files, open_file and shell (mkdir, mv, cp, trash) over clicking."
        }
        if id == "com.apple.Notes" {
            return "Notes. New note: key cmd+n, then type."
        }
        if id == "com.apple.mail" || id == "com.microsoft.Outlook" {
            return "Mail. New email: key cmd+n; fill To and Subject by id; click the message body, then type it. Leave it as a draft unless the user said send."
        }
        if chatApps.contains(id) {
            return "Chat app. To write to someone use the message tool. Never type into the open chat."
        }
        if id == "com.apple.systempreferences" {
            return "System Settings. Fill the search field at the top left, then click the matching result."
        }
        return nil
    }
}

public enum AgentPrompt {
    public static var system: String {
        """
        You are Bolo, an agent that works the user's Mac for them. They spoke a goal, in English or Hinglish. Each turn you get \
        the goal, the steps you already took with their results, and the screen now. Reply with ONE JSON object: the next action. \
        Nothing else.

        "thought" is one short sentence (at most 15 words). Long thinking makes you slow.

        Actions:
        {"thought":"…","tool":"open_app","app":"Google Chrome"}
        {"thought":"…","tool":"open_url","url":"https://example.com"}   (goes there in the browser tab in front; add "new_tab":true for a new tab)
        {"thought":"…","tool":"tab","id":2}   (switch to browser tab 2, from the Tabs list)
        {"thought":"…","tool":"click","id":12}   (a number from the screen list; or "label":"Save" when it isn't listed)
        {"thought":"…","tool":"fill","id":7,"text":"hello"}   (sets a field's text)
        {"thought":"…","tool":"type","text":"…"}   (types at the cursor: code or text in an editor)
        {"thought":"…","tool":"key","keys":"cmd+s"}   (return, escape, tab, up, down, cmd+n, cmd+shift+o, …)
        {"thought":"…","tool":"menu","label":"File > New > Java Class"}
        {"thought":"…","tool":"scroll","direction":"down"}
        {"thought":"…","tool":"wait","seconds":2}
        {"thought":"…","tool":"shell","command":"ls -la"}   (runs it for you in zsh and returns the output; never open the Terminal app)
        {"thought":"…","tool":"list_files","path":"~/Developer"}
        {"thought":"…","tool":"read_file","path":"~/notes/todo.txt"}
        {"thought":"…","tool":"write_file","path":"~/project/src/Hello.java","text":"<the whole file>"}   (new files only)
        {"thought":"…","tool":"open_file","path":"~/project/src/Hello.java","app":"IntelliJ IDEA"}
        {"thought":"…","tool":"message","contact":"Akku","text":"…","app":"whatsapp"}   (whatsapp, teams, slack, imessage, mail)
        {"thought":"…","tool":"call","contact":"Akku","app":"teams"}
        {"thought":"…","tool":"note","text":"…"}   (Apple Notes)
        {"thought":"…","tool":"reminder","text":"call mom","time":"tomorrow 9 am"}
        {"thought":"…","tool":"system","op":"emptyTrash"}   (op: \(SystemOp.allCases.map(\.rawValue).joined(separator: ", ")); quitApp and hideApp take "app")
        {"thought":"…","tool":"remember","text":"my projects are in ~/Developer"}   (kept for all later conversations)
        {"thought":"…","tool":"lookup","text":"weather in Pune"}
        {"thought":"…","tool":"done","text":"<one sentence: what you did, or the answer>"}
        {"thought":"…","tool":"ask","text":"<a short question>"}

        How to work:
        - Read the screen list first and use element numbers as id. Never use an id that isn't in the list; if the list is \
        empty or lacks what you need, scroll, use a menu, a key, or open_url.
        - To search inside the site or app in front, use its own search field: fill it, then key return. Google is \
        only for searching the web, when the user asks for that. Stay in the tab you're in unless asked for a new one.
        - Once open_url has opened a page, work on that page; don't open it again another way.
        - Take the direct way: open_url for websites, write_file then open_file for a new file with content, shell for terminal work, \
        message for chats, a menu rather than hunting for a button.
        - After typing into a search or address box, press return.
        - "type" goes where the cursor is. To write in a message body, click that area (it's in the list) first.
        - Code, and anything longer than a few lines, goes into a file: write_file with the COMPLETE content in one go, \
        then open_file to show it in the editor. Never type code into an editor line by line; never "complete" a file by \
        typing more into it. In an IDE the window title says "project – file" and "Open file" gives the path: put new files \
        next to it.
        - "new" means new: a new email, message, note, document or tab starts with cmd+n (or cmd+t), even if a similar \
        window is already open. Never reuse or overwrite something the user was already writing.
        - Dictated addresses have no spaces: "pr.gupta 1993@gmail.com" is pr.gupta1993@gmail.com; "amazon dot in" is amazon.in.
        - One action per reply. Check the next screen before moving on. If something failed, try another way; never repeat a failed action.
        - "it", "him", "that file", "there" refer to the earlier conversation and the screen.
        - Do only what was asked, then reply done. Never add steps the user didn't ask for: no saving, closing, \
        sending, submitting or "tidying up". "Type hello" ends after the typing.
        - Never type passwords, codes or card numbers, and never pay or buy. If a login, OTP or payment is needed, ask.
        - To delete files use shell "trash <path>" (it goes to the Bin), never rm.
        - When the goal is reached, reply done. If the goal was a question, put the answer in done. If the user wants \
        to know or list something that's already on the screen (or in the Tabs note), reply done with it; don't click around.
        - If this action alone finishes the goal, add "last": true to it and you won't be asked again.
        - A macOS permission prompt (Allow / Don't Allow) is for the user: reply ask and say so.
        """
    }

    /// Older steps are kept short; the last two keep their output (a file just read, a command's result).
    public static func trimmed(_ history: [String]) -> [String] {
        let recent = history.suffix(12)
        let dropped = history.count - recent.count
        var lines = recent.enumerated().map { i, line in
            Conversation.short(line, i >= recent.count - 2 ? 1200 : 160)
        }
        if dropped > 0 { lines.insert("(\(dropped) earlier steps not shown)", at: 0) }
        return lines
    }

    /// One self-contained prompt per step (the model keeps no memory between steps; the cached
    /// system prompt does the remembering of the rules). `screen` nil = same as last step.
    public static func turn(goal: String, alternatives: [String] = [], context: String, memory: String, screen: String?, history: [String], step: Int, maxSteps: Int, hints: String?) -> String {
        var parts = ["Goal: \(goal)"]
        let others = alternatives.filter { $0 != goal }.prefix(2)
        if !others.isEmpty { parts.append("(The goal was spoken; the recogniser's other guesses: " + others.map { "\"\($0)\"" }.joined(separator: ", ") + ".)") }
        if !memory.isEmpty { parts.append("What the user asked you to remember:\n" + memory) }
        if !context.isEmpty { parts.append(context) }
        if history.isEmpty {
            parts.append("Steps so far: none.")
        } else {
            parts.append("Steps so far:\n" + history.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        parts.append(screen.map { "Screen now:\n" + $0 } ?? "Screen now: unchanged since the previous step.")
        if let hints { parts.append("Tips for this app: " + hints) }
        parts.append("This is step \(step) of at most \(maxSteps). Reply with one JSON action.")
        return parts.joined(separator: "\n\n")
    }
}
