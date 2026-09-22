import Foundation

/// Finds and resolves spoken times: "at 5 pm", "tomorrow at 9", "in 10 minutes", "10 minute baad".
public enum TimePhrase {
    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10,
        "fifteen": 15, "twenty": 20, "thirty": 30, "half an": 30,
    ]

    private static let relative = try! NSRegularExpression(
        pattern: "\\b(?:in|after) (\\d+|half an|an|a|one|two|three|four|five|ten|fifteen|twenty|thirty) (minute|min|hour|hr|day)s?\\b"
            + "|\\b(\\d+) (minute|min|hour|ghante|ghanta|din)s? (?:baad|mein|me)\\b",
        options: .caseInsensitive)

    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Hinglish clock time: "6 baje" (after HearingFixes turns "che baji" into "6 baje").
    private static let baje = try! NSRegularExpression(pattern: "\\b(\\d{1,2})\\s*baje\\b", options: .caseInsensitive)

    /// Range of the time phrase in `s`, widened to swallow a leading "at"/"on"/"by".
    public static func find(in s: String) -> Range<String.Index>? {
        let whole = NSRange(s.startIndex..., in: s)
        let match = relative.firstMatch(in: s, range: whole) ?? baje.firstMatch(in: s, range: whole) ?? detector.firstMatch(in: s, range: whole)
        guard let m = match, var r = Range(m.range, in: s) else { return nil }
        let before = s[..<r.lowerBound]
        if let p = before.range(of: "(?:\\s|^)(?:at|on|by|around|till)\\s+$", options: [.regularExpression, .caseInsensitive]) {
            r = p.lowerBound..<r.upperBound
        }
        return r
    }

    /// Absolute date for a phrase found by `find`. A bare clock time already past today means tomorrow.
    public static func resolve(_ phrase: String, now: Date = Date()) -> Date? {
        let whole = NSRange(phrase.startIndex..., in: phrase)
        if let m = relative.firstMatch(in: phrase, range: whole) {
            let amountGroup = m.range(at: 1).location != NSNotFound ? 1 : 3
            let unitGroup = amountGroup == 1 ? 2 : 4
            guard let a = Range(m.range(at: amountGroup), in: phrase), let u = Range(m.range(at: unitGroup), in: phrase) else { return nil }
            let amountText = phrase[a].lowercased()
            guard let amount = Int(amountText) ?? numberWords[amountText] else { return nil }
            let unit = phrase[u].lowercased()
            let seconds: Double =
                unit.hasPrefix("min") ? 60 : (unit.hasPrefix("h") || unit.hasPrefix("gh")) ? 3600 : 86400
            return now.addingTimeInterval(Double(amount) * seconds)
        }
        if let m = baje.firstMatch(in: phrase, range: whole), let r = Range(m.range(at: 1), in: phrase), let hour = Int(phrase[r]), (1...12).contains(hour) {
            // No am/pm in "6 baje": take the next 6 o'clock, morning or evening.
            let cal = Calendar.current
            let options = [hour % 12, hour % 12 + 12].compactMap { cal.date(bySettingHour: $0, minute: 0, second: 0, of: now) }
            if let next = options.filter({ $0 > now }).min() { return next }
            return cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: hour % 12, minute: 0, second: 0, of: now)!)
        }
        guard let m = detector.firstMatch(in: phrase, range: whole), let date = m.date else { return nil }
        let saysDay = phrase.range(of: "tomorrow|today|monday|tuesday|wednesday|thursday|friday|saturday|sunday|kal|\\d{1,2}(st|nd|rd|th)",
                                   options: [.regularExpression, .caseInsensitive]) != nil
        if !saysDay, date < now { return Calendar.current.date(byAdding: .day, value: 1, to: date) }
        return date
    }
}
