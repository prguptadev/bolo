import Foundation

/// Turns a spoken sentence into steps using fixed phrase patterns, in English and Hinglish.
///
/// Nothing here guesses. If a clause matches no pattern the whole sentence returns `nil`,
/// and the caller falls back to the on-device model (whose output is then grounded).
public struct CommandParser: Sendable {
    /// Lowercased names that can start a "who" slot: nicknames, full names, first names.
    /// Longest first, so "priya sharma" wins over "priya".
    public let knownNames: [String]
    /// Lowercased installed app names. When set, "open X" only matches apps that exist, so
    /// "whatsapp bhai saying bring milk and open the door" stays one message.
    public let knownApps: Set<String>

    public init(knownNames: [String] = [], knownApps: Set<String> = []) {
        self.knownNames = Array(Set(knownNames.map { $0.lowercased() }.filter { !$0.isEmpty }))
            .sorted { $0.count > $1.count }
        self.knownApps = Set(knownApps.map { $0.lowercased() })
    }

    /// Tries the best transcript, then the speech engine's alternatives, each after `HearingFixes`.
    /// Returns the first that forms a command and which candidate it was (0 = best).
    public func parse(candidates: [String]) -> (command: Command, index: Int)? {
        for (i, raw) in candidates.enumerated() {
            // Clean first (commas, fillers, punctuation), so fixes see "Che Baji Ya De Lana", not "Che, Baji, Ya, De, Lana".
            let fixed = HearingFixes.apply(Self.clean(raw))
            if var command = parse(fixed) {
                command.utterance = raw
                return (command, i)
            }
        }
        return nil
    }

    public func parse(_ utterance: String) -> Command? {
        let cleaned = Self.clean(utterance)
        guard !cleaned.isEmpty else { return nil }

        // "open WhatsApp chat with mom and send …" is one command; don't split at "and send".
        for pattern in Self.wholeSentence {
            if let c = pattern.match(cleaned), let step = pattern.build(self, c) {
                return Command(utterance: utterance, steps: [step], source: .rules)
            }
        }

        // A clause that doesn't parse on its own is glued back onto the previous one:
        // "tell bhai I'll be late and call you later" is one message, not two commands.
        var groups: [(connector: String, text: String)] = []
        for (connector, clause) in Self.splitClauses(cleaned) {
            if let last = groups.last, parseClause(clause) == nil {
                groups[groups.count - 1].text = last.text + " " + connector + " " + clause
            } else {
                groups.append((connector, clause))
            }
        }
        var steps: [Step] = []
        var texts: [String] = []
        for (connector, group) in groups {
            guard var step = parseClause(group) else { return nil }
            let isMessage = [.sendMessage, .draftMessage, .call].contains(step.action)
            // "open WhatsApp and type Prashant Gupta, bye-bye": typing right after opening a chat app is a
            // message to someone, never typing into whichever chat happens to be open.
            if step.action == .typeText, let last = steps.last, last.action == .openApp,
                let ch = last.app.flatMap(Self.channel(forApp:))
            {
                let (who, msg) = splitWho(step.text ?? "")
                let known = knownNames.contains(who.lowercased())
                guard known || knownNames.isEmpty, !msg.isEmpty, let message = messageStep(who: who, msg: msg, ch: ch.rawValue, send: false)
                else { return nil }  // not sure who it's for: let the model reason about it, or ask
                step = message
                steps.removeLast()
                texts.removeLast()
            }
            // "open WhatsApp and send message to Aku …": the app only says where the message goes.
            if isMessage, step.channel == nil, let last = steps.last, last.action == .openApp,
                let ch = last.app.flatMap(Self.channel(forApp:))
            {
                step.channel = ch
                steps.removeLast()
                texts.removeLast()
            }
            // "send message to Vasu or send message to Akku": "or" between two of the same is a correction.
            let messages: Set<Action> = [.sendMessage, .draftMessage]
            if connector.lowercased() == "or", let last = steps.last,
                last.action == step.action || (messages.contains(last.action) && messages.contains(step.action))
            {
                if step.channel == nil { step.channel = last.channel }
                steps.removeLast()
                texts.removeLast()
            }
            // "tell bhai to click the link and press submit": a screen action right after a message is
            // part of the message, never a separate click.
            if step.action.drivesScreen, let last = steps.last, last.action == .sendMessage || last.action == .draftMessage,
                let merged = parseClause(texts[texts.count - 1] + " and " + group),
                merged.action == .sendMessage || merged.action == .draftMessage
            {
                steps[steps.count - 1] = merged
                texts[texts.count - 1] += " and " + group
                continue
            }
            steps.append(step)
            texts.append(group)
        }
        // "new note a small joke" asks for a joke, not those words: leave writing to the model.
        if steps.contains(where: { [.newNote, .typeText, .draftMessage, .sendMessage].contains($0.action) && Intent.isContentRequest($0.text ?? "") }) {
            return nil
        }
        return Command(utterance: utterance, steps: steps, source: .rules)
    }

    // MARK: - Cleaning and splitting

    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "[\"“”«»]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s*:\\s*", with: " saying ", options: .regularExpression)
        // Speech engines often drop "and" but put a comma at the pause: "…five minutes, remind me at 5".
        t = t.replacingOccurrences(
            of: ",\\s+(?=(?:remind me|open |launch |search |google |join |new note|set a reminder|lock |mute|volume |run ))",
            with: " and ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "[,;]", with: " ", options: .regularExpression)
        // A full stop only separates two commands when a command follows; otherwise it's just a pause
        // ("send message to Aku. I hate you" is one message).
        t = t.replacingOccurrences(of: "[.!?]+\\s+(?=" + clauseStart + "\\b)", with: " and ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "[.!?]+\\s+(?=\\S)", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
        // "github dot com" -> "github.com"
        t = t.replacingOccurrences(
            of: "(\\w)\\s+dot\\s+(com|in|org|io|net|dev|ai|co|app)\\b", with: "$1.$2",
            options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(
            of: "^(?:(?:hey|ok|okay|now|so|alright|and|bolo)\\s+)*(?:(?:please|can you|could you|will you|would you|kindly)\\s+)*",
            with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+please$", with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static let clauseStart =
        "(?:open|launch|start|switch to|send|message|text|whatsapp|teams|imessage|tell|remind|set a reminder|"
        + "search|google|youtube|look up|play|new note|create a note|make a note|add a note|take a note|note|"
        + "join|type|write|call|set volume|volume|mute|unmute|lock|run|go to|visit|"
        + "click|tap|press|hit|select|choose|scroll|go back|copy|paste|undo|redo|save|close|new tab|new window|refresh|menu|"
        + "give me|calculate|what's|what is|add|solve|"
        + "\\S+ ko (?:whatsapp|teams|message|msg|text|call|bolo|bhejo|batao))"

    private static let splitter = try! NSRegularExpression(
        pattern: "\\s+(and then|and also|and|then|aur phir|aur|phir|or)\\s+(?=" + clauseStart + "\\b)",
        options: .caseInsensitive)

    /// Splits "A and B then C" into [("", A), ("and", B), ("then", C)] where B and C start like a command.
    static func splitClauses(_ s: String) -> [(connector: String, clause: String)] {
        var out: [(String, String)] = []
        var start = s.startIndex
        var connector = ""
        for m in splitter.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s), let c = Range(m.range(at: 1), in: s) else { continue }
            out.append((connector, String(s[start..<r.lowerBound])))
            connector = String(s[c])
            start = r.upperBound
        }
        out.append((connector, String(s[start...])))
        return out
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.1.isEmpty }
    }

    // MARK: - Patterns

    private typealias Captures = [String: String]

    private struct Pattern {
        let regex: NSRegularExpression
        let names: [String]
        let build: (CommandParser, Captures) -> Step?

        init(_ pattern: String, _ build: @escaping (CommandParser, Captures) -> Step?) {
            regex = try! NSRegularExpression(pattern: "^" + pattern + "$", options: .caseInsensitive)
            let nameRegex = try! NSRegularExpression(pattern: "\\(\\?<([a-zA-Z][a-zA-Z0-9]*)>")
            names = nameRegex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern))
                .compactMap { Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) } }
            self.build = build
        }

        func match(_ s: String) -> Captures? {
            guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
            var out: Captures = [:]
            for name in names {
                if let r = Range(m.range(withName: name), in: s) {
                    out[name] = String(s[r]).trimmingCharacters(in: .whitespaces)
                }
            }
            return out
        }
    }

    private static let ch = "(?<ch>whats ?app|microsoft teams|teams|imessage|slack|sms|text|message|msg)"
    private static let chatApp = "(?<ch>whats ?app|microsoft teams|teams|imessage|slack)"
    private static let say = "(?:saying|that says|and say|and tell (?:him|her|them)|telling (?:him|her|them)|that|ki)"

    private static let wholeSentence: [Pattern] = [
        Pattern("open (?:the )?" + chatApp + " (?:chat )?(?:with|of|for) (?<who>.+?) and (?<verb>send|write|type|likho) (?:a message )?(?:saying |that )?(?<msg>.+)") {
            p, c in p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: c["verb"]?.lowercased() == "send")
        },
        Pattern("open (?:my )?(?<who>.+?)(?:'s|s) " + chatApp + "(?: chat)? and (?<verb>send|write|type|likho) (?:a message )?(?:saying |that )?(?<msg>.+)") {
            p, c in p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: c["verb"]?.lowercased() == "send")
        },
    ]

    private static let patterns: [Pattern] = [
        // Calls come before messaging so "teams call priya" isn't read as a message to "call".
        Pattern("(?:make a |start a )?(?<ch>teams|whats ?app|facetime) call (?:to |with )?(?<who>.+)") { p, c in
            p.callStep(who: c["who"], ch: c["ch"])
        },
        Pattern("call (?<who>.+?) on (?<ch>teams|whats ?app|facetime)") { p, c in
            p.callStep(who: c["who"], ch: c["ch"])
        },
        Pattern("(?<who>.+?) ko (?:(?<ch>teams|whats ?app) (?:pe |par |on )?)?call (?:karo|kar do|lagao|laga do)") {
            p, c in p.callStep(who: c["who"], ch: c["ch"] ?? "teams")
        },
        Pattern("(?<who>.+?) ko call (?:karo|kar do|lagao|laga do) (?<ch>teams|whats ?app) (?:pe|par)") { p, c in
            p.callStep(who: c["who"], ch: c["ch"])
        },

        // Open a chat, optionally typing or sending text.
        Pattern("open (?:the )?" + chatApp + " (?:chat )?(?:with|of|for) (?<who>.+?)(?: and (?<verb>send|write|type|likho) (?<msg>.+))?") {
            p, c in p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: c["verb"]?.lowercased() == "send")
        },
        Pattern("open (?:my )?(?<who>.+?)(?:'s|s) " + chatApp + "(?: chat)?(?: and (?<verb>send|write|type|likho) (?<msg>.+))?") {
            p, c in p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: c["verb"]?.lowercased() == "send")
        },

        // "open the family group on whatsapp" / "open design team chat on slack"
        Pattern("open (?:the |my )?(?<who>.+?)(?: chat| group chat| group| channel)? (?:on|in) " + chatApp) { p, c in
            p.messageStep(who: c["who"], msg: "", ch: c["ch"], send: false)
        },

        // English messaging. "write / type / draft a message" = draft; "send / message / tell" = send.
        Pattern("(?:write|type|draft|compose) (?:a |an )?(?:message|msg|text|note) (?:to |for )(?<who>.+?) on " + chatApp + "(?: " + say + ")? (?<msg>.+)") {
            p, c in p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: false)
        },
        Pattern("(?:write|type|draft|compose) (?:a |an )?(?:message|msg|text) (?:to |for )(?<rest>.+)") { p, c in
            p.messageStep(rest: c["rest"], ch: nil, send: false)
        },
        Pattern("(?:send )?(?:a )?(?:message|msg|text) (?:to )?(?<who>.+?) on " + chatApp + "(?: " + say + ")? (?<msg>.+)") {
            p, c in p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: true)
        },
        Pattern("(?:send )?(?:an? )?" + ch + " (?:message |msg )?to (?<rest>.+)") { p, c in
            p.messageStep(rest: c["rest"], ch: c["ch"], send: true)
        },
        Pattern("tell (?<who>.+?) on " + chatApp + " (?:that )?(?<msg>.+)") { p, c in
            p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: true)
        },
        Pattern("let (?<who>.+?) know on " + chatApp + "(?: that)? (?<msg>.+)") { p, c in
            p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: true)
        },
        Pattern("let (?<who>.+?) know(?: that)? (?<msg>.+)") { p, c in
            p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: nil, send: true)
        },
        Pattern("tell (?<rest>.+)") { p, c in
            p.messageStep(rest: c["rest"], ch: nil, send: true)
        },

        // Hinglish messaging: "bhai ko whatsapp karo ki ...", "priya ko teams pe message karo ...".
        Pattern("(?<who>.+?) ko (?:(?<ch>whats ?app|teams|imessage|message|msg|text|sms) (?:pe |par |on )?)?(?<verb>message karo|msg karo|message kar do|karo|kar do|kardo|bhejo|bhej do|bhejdo|likho|likh do|bolo|bol do|batao|bata do|bataa do)(?: (?:ki|that|saying))?(?: (?<msg>.+))?") {
            p, c in
            let verb = c["verb"]?.lowercased() ?? ""
            return p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: !verb.hasPrefix("likh"))
        },
        Pattern("(?<who>.+?) ko (?:(?<ch>whats ?app|teams) (?:pe |par |on )?)?(?<msg>.+?) (?<verb>bolo|bol do|batao|bata do|bhejo|bhej do|likho|likh do|message karo|msg karo|whats ?app karo)") {
            p, c in
            let verb = c["verb"]?.lowercased() ?? ""
            return p.messageStep(who: c["who"], msg: c["msg"] ?? "", ch: c["ch"], send: !verb.hasPrefix("likh"))
        },

        // Arithmetic, answered in the notch: "5+5", "sum of 5+5", "what's 18% of 2300", "12 times 7 kitna hai"
        Pattern("(?:add|do|type|enter|put|calculate|compute|solve)(?: in)? (?<expr>[-+*/x×÷().%\\d ]+[-+*/x×÷][-+*/x×÷().%\\d ]+)") { _, c in
            c["expr"].flatMap { Arithmetic.expression($0) != nil ? Step(.calculate, text: $0.trimmingCharacters(in: .whitespaces)) : nil }
        },
        Pattern("(?:give me |tell me |what(?:'s| is) |calculate |compute )?(?:the )?(?:sum|total|answer|result|value) of (?<expr>.+?)(?: please)?") { _, c in
            c["expr"].flatMap { Arithmetic.expression($0) != nil ? Step(.calculate, text: $0) : nil }
        },
        Pattern("(?:what(?:'s| is)|calculate|compute|how much is)? ?(?<expr>[-+*/x×÷().%\\d ]+(?:(?: plus| minus| times| into| multiplied by| divided by| over| percent of) [-+*/().%\\d ]+)*)(?: kitna (?:hai|hota hai|hua))?") { _, c in
            c["expr"].flatMap { Arithmetic.expression($0) != nil ? Step(.calculate, text: $0.trimmingCharacters(in: .whitespaces)) : nil }
        },

        // Notes.
        Pattern("(?:(?:create|make|add|take|write) (?:a )?(?:new )?note|new note|note down|note likho|note banao|note)(?: " + say + "| to)? (?<msg>.+)") {
            _, c in c["msg"].map { Step(.newNote, text: $0) }
        },
        Pattern("(?<msg>.+?) (?:ka |ki )?note (?:banao|bana do|likho|likh do)") { _, c in
            c["msg"].map { Step(.newNote, text: $0) }
        },

        // Reminders.
        Pattern("(?:remind me|set a reminder|set reminder|add a reminder|reminder)(?: to| for)? (?<rest>.+)") { _, c in
            c["rest"].flatMap(CommandParser.reminderStep)
        },
        Pattern("(?:don['’]?t|do not) let me forget(?: to| about)? (?<rest>.+)") { _, c in
            c["rest"].flatMap(CommandParser.reminderStep)
        },
        // "mujhe 6 baje yaad dilana ki gym jaana hai"
        Pattern("(?:mujhe |humein )?(?<when>.+?) (?:yaad dilana|yaad dila dena|yaad dilao|remind karna)(?: ki| ke| to)? (?<text>.+)") { _, c in
            guard let text = c["text"], let when = c["when"] else { return nil }
            return CommandParser.reminderStep(text + " " + when)
        },

        // Web search.
        Pattern("(?<eng>google|youtube|search) (?:karo|kar do|pe search karo) (?<q>.+)") { _, c in
            CommandParser.searchStep(c["q"], c["eng"])
        },
        Pattern("(?<q>.+?) (?:(?<eng>google|youtube) )?(?:search karo|search kar do|google karo|google kar do)") { _, c in
            CommandParser.searchStep(c["q"], c["eng"])
        },
        Pattern("(?:search|google|look up) (?:on )?(?<eng>youtube|google) (?:for )?(?<q>.+)") { _, c in
            CommandParser.searchStep(c["q"], c["eng"])
        },
        Pattern("(?:search|google|look up) (?:for )?(?<q>.+?)(?: on (?<eng>youtube|google))?") { _, c in
            CommandParser.searchStep(c["q"], c["eng"])
        },
        Pattern("youtube (?:search )?(?:for )?(?<q>.+)") { _, c in CommandParser.searchStep(c["q"], "youtube") },
        Pattern("play (?<q>.+?) on youtube") { _, c in CommandParser.searchStep(c["q"], "youtube") },
        Pattern("(?<eng>youtube|google) (?:pe|par) (?<q>.+?) (?:search karo|search kar do|dhundo|chalao|lagao)") { _, c in
            CommandParser.searchStep(c["q"], c["eng"])
        },

        // Meetings.
        Pattern("join (?:my |the )?(?:next )?(?:teams |zoom |google meet )?(?:meeting|call)(?: now)?") { _, _ in
            Step(.joinNextMeeting)
        },
        Pattern("(?:next )?meeting (?:join karo|join kar do|join)") { _, _ in Step(.joinNextMeeting) },

        // System.
        Pattern("(?:turn |set )?(?:the )?volume (?:up |down )?(?:to )?(?<n>\\d{1,3})(?: ?%| percent)?") { _, c in
            c["n"].flatMap(Int.init).map { Step(.setVolume, number: min($0, 100)) }
        },
        Pattern("(?:turn )?(?<v>mute|unmute)(?: (?:the )?(?:volume|sound|audio|mac))?") { _, c in
            Step(c["v"]?.lowercased() == "unmute" ? .unmute : .mute)
        },
        Pattern("(?:awaaz|sound|volume) band karo") { _, _ in Step(.mute) },
        Pattern("lock(?: (?:the|my))?(?: (?:screen|mac|computer|laptop))?") { _, _ in Step(.lockScreen) },
        Pattern("(?:screen|mac|laptop) lock karo") { _, _ in Step(.lockScreen) },
        Pattern("run (?:my |the )?(?<name>.+?) shortcut") { _, c in c["name"].map { Step(.runShortcut, text: $0) } },
        Pattern("run shortcut (?<name>.+)") { _, c in c["name"].map { Step(.runShortcut, text: $0) } },

        // Screen control. Keys and shortcuts first, so "press enter" is a key and "save" isn't a click.
        Pattern("press (?:the )?(?<keys>(?:(?:command|cmd|control|ctrl|option|alt|shift)[ +-]+)*(?:enter|return|escape|esc|tab|spacebar|space|delete|backspace|up|down|left|right|page up|page down|home|end|[a-z0-9]))(?: key)?") { _, c in
            c["keys"].flatMap(KeyCombo.canonical).map { Step(.pressKey, text: $0) }
        },
        Pattern("(?<keys>enter|return|escape|tab|space|delete) (?:dabao|daba do|press karo)") { _, c in
            c["keys"].flatMap(KeyCombo.canonical).map { Step(.pressKey, text: $0) }
        },
        Pattern("(?:open )?(?:a )?(?<name>select all|copy|paste|cut|undo|redo|save|close window|close tab|new tab|new window|refresh|reload|zoom in|zoom out)(?: (?:this|that|it|the file|the page|here|everything))?(?: karo| kar do)?") { _, c in
            c["name"].flatMap { KeyCombo.named[$0.lowercased()] }.map { Step(.pressKey, text: $0) }
        },
        // Menus: "File menu export as PDF", "choose Make Plain Text from the Format menu", "menu Export as PDF"
        Pattern("(?:click |choose |select |open |go to )?(?:the )?(?<menu>[a-z]+) menu (?:and )?(?:then )?(?:click |choose |select )?(?<item>.+)") { _, c in
            guard let m = c["menu"], let i = c["item"] else { return nil }
            return Step(.menu, target: m + " > " + i)
        },
        Pattern("(?:click|choose|select|pick) (?<item>.+?) (?:in|from|under) (?:the )?(?<menu>[a-z]+) menu") { _, c in
            guard let m = c["menu"], let i = c["item"] else { return nil }
            return Step(.menu, target: m + " > " + i)
        },
        Pattern("(?:use |click |choose |select )?(?:the )?menu (?:item |option )?(?<item>.+)") { _, c in
            c["item"].map { Step(.menu, target: $0) }
        },
        Pattern("(?<menu>file|edit|view|format|window|help|history|bookmarks) (?<item>(?:export|save|print|open|close|new|duplicate|rename|move|revert|undo|redo|copy|paste|select|find|show|hide|enter|exit|zoom|minimize|make|convert|font|spelling|share)\\b.*)") { _, c in
            guard let m = c["menu"], let i = c["item"] else { return nil }
            return Step(.menu, target: m + " > " + i)
        },
        // Scrolling and going back
        Pattern("scroll (?:to (?:the )?)?(?<dir>up|down|left|right|top|bottom)(?: (?:by )?(?<n>\\d+))?(?: (?:times|pages?))?") { _, c in
            c["dir"].map { Step(.scroll, text: $0.lowercased(), number: c["n"].flatMap(Int.init)) }
        },
        Pattern("(?<dir>neeche|niche|upar|oopar)(?: scroll)? (?:karo|kar do|jao)") { _, c in
            c["dir"].map { Step(.scroll, text: ["neeche", "niche"].contains($0.lowercased()) ? "down" : "up") }
        },
        Pattern("(?:go back|back|peeche jao|wapas jao|back jao)") { _, _ in Step(.goBack) },
        // Typing into a named field: needs "field/box/bar/input" (or "search") so a message with "in the" isn't split
        Pattern("(?:type|write|enter|likho) (?<text>.+) (?:in|into) (?:the )?(?<target>.+?) (?:field|box|bar|input)") { _, c in
            guard let t = c["text"], let f = c["target"] else { return nil }
            return Step(.typeInto, text: t, target: f)
        },
        Pattern("(?:type|write|enter) (?<text>.+) (?:in|into) (?:the )?(?<target>search|address bar|url bar)") { _, c in
            guard let t = c["text"], let f = c["target"] else { return nil }
            return Step(.typeInto, text: t, target: f)
        },
        // Clicking by label
        Pattern("(?:click|tap|press|hit)(?: on)?(?: the)? (?<target>.+?)(?: button| link| tab| icon| option| checkbox| row)?") { _, c in
            c["target"].map { Step(.click, target: $0) }
        },
        Pattern("(?:select|choose|pick)(?: the)? (?<target>.+?)(?: option| item| row)?") { _, c in
            c["target"].map { Step(.click, target: $0) }
        },
        Pattern("(?<target>.+?) (?:pe|par) click (?:karo|kar do)") { _, c in c["target"].map { Step(.click, target: $0) } },
        Pattern("(?<target>.+?) (?:dabao|daba do|press karo|click karo)") { _, c in c["target"].map { Step(.click, target: $0) } },

        // Mac system operations (English and Hinglish).
        Pattern("(?:empty|clear|clean)(?: out)? (?:the |my )?(?:trash|bin|dustbin|recycle bin)|(?:trash|bin|dustbin) (?:khali|saaf|empty|clear) (?:karo|kar do)") { _, _ in
            CommandParser.system(.emptyTrash)
        },
        Pattern("open (?:the |my )?(?:trash|bin|dustbin)") { _, _ in CommandParser.system(.openTrash) },
        Pattern("(?:open|show|go to) (?:my |the )?(?<f>downloads|desktop|documents|home|applications)(?: folder)?") { _, c in
            CommandParser.system(.openFolder, text: c["f"]?.lowercased())
        },
        Pattern("(?:make|create|new) (?:a )?(?:new )?folder(?: (?:called|named) (?<name>.+))?") { _, c in
            CommandParser.system(.newFolder, text: c["name"])
        },
        Pattern("eject (?:all )?(?:the )?(?:disks?|drives?|usb|pen ?drives?)") { _, _ in CommandParser.system(.ejectAll) },
        Pattern("(?:put )?(?:the )?(?:mac|computer|laptop) (?:to )?sleep|sleep (?:the )?(?:mac|computer|laptop)|go to sleep|(?:mac|laptop) (?:ko )?(?:so ja|sula do)") { _, _ in
            CommandParser.system(.sleep)
        },
        Pattern("(?:restart|reboot)(?: the)?(?: mac| computer| laptop)?|(?:mac|laptop) (?:ko )?restart (?:karo|kar do)") { _, _ in CommandParser.system(.restart) },
        Pattern("(?:shut ?down|power off|turn off)(?: the)? (?:mac|computer|laptop)|shut ?down|(?:mac|laptop) (?:ko )?band (?:karo|kar do)") { _, _ in
            CommandParser.system(.shutdown)
        },
        Pattern("(?:log|sign) ?out") { _, _ in CommandParser.system(.logout) },
        Pattern("(?:turn on |enable |switch to )?dark mode(?: on| chalu (?:karo|kar do))?") { _, _ in CommandParser.system(.darkModeOn) },
        Pattern("(?:turn off dark mode|dark mode off|disable dark mode|(?:turn on |switch to )?light mode)") { _, _ in CommandParser.system(.darkModeOff) },
        Pattern("(?:take (?:a )?)?screen ?shot(?: lo| le lo)?") { _, _ in CommandParser.system(.screenshot) },
        Pattern("(?:increase|raise|turn up) (?:the )?brightness|brightness (?:up|badhao|zyada karo)|(?:make (?:the )?screen )?brighter") { _, _ in
            CommandParser.system(.brightnessUp)
        },
        Pattern("(?:decrease|lower|reduce|turn down) (?:the )?brightness|brightness (?:down|kam karo)|(?:make (?:the )?screen )?dimmer") { _, _ in
            CommandParser.system(.brightnessDown)
        },
        Pattern("(?:turn )?(?<s>on|off) (?:the )?wi-?fi|wi-?fi (?<s2>on|off|chalu|band)(?: karo| kar do)?") { _, c in
            let s = (c["s"] ?? c["s2"] ?? "").lowercased()
            return CommandParser.system(s == "on" || s == "chalu" ? .wifiOn : .wifiOff)
        },
        Pattern("keep (?:the )?(?:mac|screen|laptop|computer) (?:awake|on)(?: for (?<n>\\d+) ?(?<u>minutes?|mins?|hours?))?") { _, c in
            let text = c["n"].map { "\($0) \(c["u"] ?? "minutes")" }
            return CommandParser.system(.keepAwake, text: text)
        },
        Pattern("(?:stop keeping (?:it |the mac )?awake|let (?:the )?(?:mac|screen) sleep)") { _, _ in CommandParser.system(.stopKeepAwake) },
        Pattern("(?:how much |what(?:'s| is) (?:the |my )?)?battery(?: level| percentage| status| left)?(?: kitni hai| kitna hai)?") { _, _ in
            CommandParser.system(.battery)
        },
        Pattern("(?:how much )?(?:free |empty )?(?:disk|storage|hard ?disk) (?:space)?(?: left| free| do i have)?(?: kitna hai)?|how much space (?:is left|do i have)") { _, _ in
            CommandParser.system(.diskSpace)
        },
        Pattern("what(?:'s| is) (?:my )?ip(?: address)?|(?:my )?ip address") { _, _ in CommandParser.system(.ipAddress) },
        Pattern("what(?:'s| is) the time|what time is it|(?:time|samay) (?:kya|kitna) (?:hai|hua)|kitne baje hain") { _, _ in CommandParser.system(.time) },
        Pattern("what(?:'s| is) (?:the |today's )?date|what day is (?:it|today)|aaj (?:kya )?(?:date|tareekh) (?:hai|kya hai)") { _, _ in CommandParser.system(.date) },
        Pattern("what(?:'s| is) (?:in |on )?(?:my |the )?clipboard|(?:read|show) (?:my |the )?clipboard") { _, _ in CommandParser.system(.clipboard) },
        Pattern("clear (?:my |the )?clipboard") { _, _ in CommandParser.system(.clearClipboard) },
        Pattern("(?:quit|close) (?:the )?(?<app>.+?)(?: app)?") { p, c in p.appStep(c["app"]).map { CommandParser.system(.quitApp, app: $0.app) } ?? nil },
        Pattern("(?<app>.+?) (?:band karo|band kar do|quit karo)") { p, c in p.appStep(c["app"]).map { CommandParser.system(.quitApp, app: $0.app) } ?? nil },
        Pattern("hide (?:the )?(?<app>.+?)(?: app)?") { p, c in p.appStep(c["app"]).map { CommandParser.system(.hideApp, app: $0.app) } ?? nil },
        Pattern("minimi[sz]e(?: (?:this|the))?(?: window)?") { _, _ in CommandParser.system(.minimize) },
        Pattern("(?:go |make it |enter )?full ?screen(?: karo)?") { _, _ in CommandParser.system(.fullScreen) },
        Pattern("show (?:the |my )?desktop|desktop dikhao") { _, _ in CommandParser.system(.showDesktop) },
        Pattern("(?:open |show )?mission control") { _, _ in CommandParser.system(.missionControl) },
        Pattern("(?:play|pause|resume|stop)(?: the)?(?: music| song| video| spotify)?|(?:gaana|music) (?:chalao|band karo|roko)") { _, _ in
            CommandParser.system(.playPause)
        },
        Pattern("(?:next|skip)(?: this)?(?: song| track)?|agla gaana") { _, _ in CommandParser.system(.nextTrack) },
        Pattern("(?:previous|last|go back a) (?:song|track)|pichla gaana") { _, _ in CommandParser.system(.previousTrack) },

        // Typing into whatever is focused.
        Pattern("(?:type|write|likho|dictate)(?: this)?(?: saying)? (?<msg>.+)") { _, c in
            c["msg"].map { Step(.typeText, text: $0) }
        },

        // Links, then apps (most general, so last).
        Pattern("(?:open|go to|visit) (?<url>(?:https?://)?[a-z0-9-]+(?:\\.[a-z0-9-]+)+(?:/\\S*)?)") { _, c in
            c["url"].map { Step(.openURL, text: $0) }
        },
        Pattern("(?:open|launch|start|switch to|show|bring up|pull up) (?:the |my )?(?<app>.+?)(?: app)?") { p, c in
            p.appStep(c["app"])
        },
        Pattern("(?<app>.+?) (?:kholo|khol do|open karo|open kar do|chalu karo|start karo)") { p, c in
            p.appStep(c["app"])
        },
        // "whatsapp bhai I'll be late" / "text mom I'm home" (after "open X" so "whatsapp kholo" opens the app).
        Pattern(ch + " (?<rest>.+)") { p, c in p.messageStep(rest: c["rest"], ch: c["ch"], send: true) },
    ]

    func parseClause(_ clause: String) -> Step? {
        for pattern in Self.patterns {
            if let captures = pattern.match(clause), let step = pattern.build(self, captures) {
                return step
            }
        }
        return nil
    }

    // MARK: - Step builders

    private static let sayRegex = try! NSRegularExpression(
        pattern: "^(?<who>.+?) " + say + " (?<msg>.+)$", options: .caseInsensitive)

    /// Splits "priya saying joining in 5" or "bhai I'll be late" into contact and message.
    func splitWho(_ rest: String) -> (who: String, msg: String) {
        if let m = Self.sayRegex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
            let w = Range(m.range(withName: "who"), in: rest), let t = Range(m.range(withName: "msg"), in: rest)
        {
            let who = String(rest[w])
            // Only trust the separator if the "who" part is short: "tell bhai that ..." not "tell ... that ...".
            if who.split(separator: " ").count <= 3 { return (who, String(rest[t])) }
        }
        let lower = rest.lowercased()
        let stripped = lower.hasPrefix("my ") ? String(lower.dropFirst(3)) : lower
        let offset = lower.count - stripped.count
        for name in knownNames where stripped == name || stripped.hasPrefix(name + " ") {
            let end = rest.index(rest.startIndex, offsetBy: offset + name.count)
            return (String(rest[..<end]), String(rest[end...]).trimmingCharacters(in: .whitespaces))
        }
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    func messageStep(rest: String?, ch: String?, send: Bool) -> Step? {
        guard let rest, !rest.isEmpty else { return nil }
        let (who, msg) = splitWho(rest)
        return messageStep(who: who, msg: msg, ch: ch, send: send)
    }

    func messageStep(who: String?, msg: String, ch: String?, send: Bool) -> Step? {
        guard let who = Self.cleanWho(who) else { return nil }
        let channel = ch.flatMap(Channel.from(spoken:))
        var text = msg.trimmingCharacters(in: .whitespaces)
        // The recognizer sometimes hears the name twice: "to AAKU Aku, bye-bye" → "bye-bye".
        let words = text.split(separator: " ", maxSplits: 1).map(String.init)
        if words.count == 2, let first = words.first?.lowercased(), let name = who.split(separator: " ").last?.lowercased(),
            first == name || (first.count >= 3 && Fuzzy.distance(first, name) <= 1)
        {
            text = words[1]
        }
        if text.isEmpty { return Step(.draftMessage, contact: who, channel: channel) }
        return Step(send ? .sendMessage : .draftMessage, contact: who, channel: channel, text: text)
    }

    static func system(_ op: SystemOp, app: String? = nil, text: String? = nil) -> Step {
        Step(.system, app: app, text: text, target: op.rawValue)
    }

    static func channel(forApp app: String) -> Channel? {
        switch app.lowercased() {
        case "whatsapp": .whatsapp
        case "microsoft teams", "teams": .teams
        case "slack": .slack
        case "messages": .imessage
        case "mail", "microsoft outlook": .mail
        default: nil
        }
    }

    func appStep(_ spoken: String?) -> Step? {
        guard let spoken, !spoken.isEmpty else { return nil }
        let name = AppNames.canonical(spoken)
        if !knownApps.isEmpty, !knownApps.contains(name.lowercased()) { return nil }
        return Step(.openApp, app: name)
    }

    func callStep(who: String?, ch: String?) -> Step? {
        guard let who = Self.cleanWho(who) else { return nil }
        return Step(.call, contact: who, channel: ch.flatMap(Channel.from(spoken:)) ?? .teams)
    }

    private static let pronouns: Set<String> = [
        "me", "us", "you", "him", "her", "them", "it", "this", "that", "everyone", "someone", "mujhe", "hume",
    ]

    static func cleanWho(_ who: String?) -> String? {
        guard var w = who?.trimmingCharacters(in: .whitespaces), !w.isEmpty else { return nil }
        w = w.replacingOccurrences(of: "^(?:my|mere|meri|to) ", with: "", options: [.regularExpression, .caseInsensitive])
        w = w.replacingOccurrences(of: "(?:'s|’s)$", with: "", options: .regularExpression)
        // A "who" that is a whole sentence means the pattern matched the wrong way round.
        guard !w.isEmpty, w.split(separator: " ").count <= 4 else { return nil }
        // "tell me a joke" is a request, not a message to someone called "me".
        guard !pronouns.contains(w.lowercased()) else { return nil }
        return w
    }

    static func searchStep(_ q: String?, _ engine: String?) -> Step? {
        guard let q, !q.isEmpty else { return nil }
        return Step(.webSearch, text: q, engine: engine?.lowercased() == "youtube" ? .youtube : .google)
    }

    /// "at 5 pm to call bhai" -> text "call bhai", time "at 5 pm".
    static func reminderStep(_ rest: String) -> Step? {
        var text = rest
        var time: String?
        if let r = TimePhrase.find(in: rest) {
            time = String(rest[r]).trimmingCharacters(in: .whitespaces)
            text = rest.replacingCharacters(in: r, with: " ")
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^(?:to|that|ki|about) ", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: " (?:at|on|by)$", with: "", options: [.regularExpression, .caseInsensitive])
        guard !text.isEmpty else { return nil }
        return Step(.addReminder, text: text, time: time)
    }
}
