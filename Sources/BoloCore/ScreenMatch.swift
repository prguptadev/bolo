import Foundation

/// How well a spoken label ("export as pdf") matches text on screen ("Export as PDF…").
/// Pure and tested; the app uses it to pick buttons, rows, fields and menu items.
public enum ScreenMatch {
    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 1.0 exact · 0.9 the label starts with what was said · 0.8 every spoken word is in the label ·
    /// 0.6 every word matches within one letter · 0 otherwise.
    public static func score(said: String, label: String) -> Double {
        let s = normalize(said), l = normalize(label)
        guard !s.isEmpty, !l.isEmpty else { return 0 }
        if s == l { return 1 }
        if l.hasPrefix(s + " ") { return 0.9 }
        let spoken = s.split(separator: " ").map(String.init)
        let words = l.split(separator: " ").map(String.init)
        // A long label that merely contains a short spoken word is weak evidence: "send" in "Sender settings".
        if spoken.allSatisfy(words.contains) { return spoken.count >= words.count / 2 ? 0.8 : 0.7 }
        let fuzzy = spoken.allSatisfy { w in words.contains { $0.count >= 4 && Fuzzy.distance(w, $0) <= 1 } }
        return fuzzy ? 0.6 : 0
    }

    public struct Pick<T> {
        public let item: T
        public let score: Double
    }

    public enum Outcome<T> {
        case found(T)
        case none
        /// Two or more equally good matches: never guess.
        case ambiguous([String])
    }

    /// The single best candidate at or above `minimum`, or `.ambiguous` when the top score is shared
    /// by items with different labels.
    public static func best<T>(_ said: String, in items: [T], label: (T) -> String, minimum: Double = 0.8) -> Outcome<T> {
        let scored = items.map { (item: $0, label: label($0), score: score(said: said, label: label($0))) }
            .filter { $0.score >= minimum }
            .sorted { $0.score > $1.score }
        guard let top = scored.first else { return .none }
        let tied = scored.filter { $0.score == top.score }
        let distinct = Set(tied.map { normalize($0.label) })
        return distinct.count > 1 ? .ambiguous(Array(distinct).sorted()) : .found(top.item)
    }
}

/// Spoken key combos to a canonical form: "command shift t" → "cmd+shift+t", "enter" → "return".
public enum KeyCombo {
    private static let modifierWords: [String: String] = [
        "command": "cmd", "cmd": "cmd", "control": "ctrl", "ctrl": "ctrl",
        "option": "opt", "alt": "opt", "opt": "opt", "shift": "shift",
    ]
    private static let keyWords: [String: String] = [
        "enter": "return", "return": "return", "escape": "escape", "esc": "escape", "tab": "tab",
        "space": "space", "spacebar": "space", "delete": "delete", "backspace": "delete",
        "up": "up", "down": "down", "left": "left", "right": "right",
        "page up": "pageup", "page down": "pagedown", "home": "home", "end": "end",
    ]

    /// nil when the words aren't a key combo.
    public static func canonical(_ spoken: String) -> String? {
        var words = spoken.lowercased().replacingOccurrences(of: "[+\\-]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        var mods: [String] = []
        while let first = words.first, let m = modifierWords[first] {
            if !mods.contains(m) { mods.append(m) }
            words.removeFirst()
        }
        let rest = words.joined(separator: " ")
        let key: String
        if let k = keyWords[rest] { key = k }
        else if rest.count == 1, rest.first!.isLetter || rest.first!.isNumber { key = rest }
        else { return nil }
        let order = ["cmd", "ctrl", "opt", "shift"]
        return (order.filter(mods.contains) + [key]).joined(separator: "+")
    }

    /// Everyday edit commands that are really shortcuts.
    public static let named: [String: String] = [
        "select all": "cmd+a", "copy": "cmd+c", "paste": "cmd+v", "cut": "cmd+x", "undo": "cmd+z",
        "redo": "cmd+shift+z", "save": "cmd+s", "close window": "cmd+w", "close tab": "cmd+w",
        "new tab": "cmd+t", "new window": "cmd+n", "refresh": "cmd+r", "reload": "cmd+r",
        "zoom in": "cmd+=", "zoom out": "cmd+-", "find": "cmd+f",
    ]
}
