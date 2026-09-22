import Foundation

/// Repairs words that an English speech model reliably mishears in Hinglish commands,
/// before the phrase parser sees them ("bye ko WhatsApp Carol" -> "bhai ko WhatsApp karo").
///
/// Each fix is anchored to command structure (start of sentence, or next to a command word),
/// so it can't rewrite the text of a message. Grow this table from eval/results/speech-*.md.
public enum HearingFixes {
    private static let rules: [(NSRegularExpression, String)] = [
        // "bhai ko ..." heard as "by/bye/buy/bai ko/co/go" at the start of a command
        ("^(?:by|bye|buy|bai|bhaiya|bhaiyya)\\s+(?:ko|co|go|koh)\\b", "bhai ko"),
        // "karo" heard as "caro/carol/kar oh/karoh" right after a channel or "ko"
        ("\\b(whats ?app|teams|message|call|ko)\\s+(?:caro|carol|kar oh|karoh|karu)\\b", "$1 karo"),
        // "bhejo" heard as "bhej o/be jo/bejo"
        ("\\b(message|msg|ko)\\s+(?:bhej o|be jo|bejo|bhejoh)\\b", "$1 bhejo"),
        // "kholo" heard as "cholo/kolo/khulo/colo" at the end of "<app> kholo"
        ("\\s(?:cholo|kolo|khulo|colo|kho lo)$", " kholo"),
        // "likho" heard as "niko/leko/lick ho/likko" ("WhatsApp Pe Niko")
        ("\\b(pe|par|ko)\\s+(?:niko|nikho|leko|lick ho|likko|leakho)\\b", "$1 likho"),
        // "WhatsApp" heard as "what's up / what sapp" when used as the app
        ("\\bko\\s+(?:what'?s ?up|what sapp?|whats sap)\\b", "ko WhatsApp"),
        ("^(?:what'?s ?up|what sapp?)\\s+(?=\\S+\\s+(?:saying|that|ki)\\b)", "WhatsApp "),
        // "yaad dilana" heard as "yard dilana / yaad de lana"
        ("\\b(?:yard|yad|yaar) (?:dilana|de lana|dila na)\\b", "yaad dilana"),
        // "Teams" heard as "team/team's/teems" ("Team call Priya", "send a team message")
        ("\\b(?:team|team's|teems|tims)\\b(?=\\s+(?:pe|par|call|message|msg|chat|karo))", "teams"),
        // "bhai" heard as "be/bye/by" right after the channel ("WhatsApp be saying …")
        ("^(whats ?app|text|message|tell)\\s+(?:be|bye|by|buy|bai)\\s+(?=(?:saying|that|ki|on)\\b)", "$1 bhai "),
        // "IntelliJ" heard as "Intelligent" when opening an app
        ("\\b(open|launch|start|switch to)\\s+intelligent\\b", "$1 intellij"),
        ("^intelligent\\s+(?=kholo\\b)", "intellij "),
        // "github dot com" heard as "get up.com"
        ("\\b(?:get ?up|git ?up|get hub)\\s*(?:\\.|dot)\\s*com\\b", "github.com"),
        // Verbs heard in a different form at the start: "Notes down", "Playing … on YouTube", "Joining my next meeting"
        ("^notes\\s+(?=down\\b)", "note "),
        ("^playing\\b(?=.*\\byoutube\\b)", "play"),
        ("^joining\\b(?=.*\\bmeeting\\b)", "join"),
        // "yaad dilana" split up ("Ya De Lana"), "baje" as "baji", and Hindi hour words before "baje"
        ("\\bya(?:ad|d)?\\s+de\\s+lana\\b", "yaad dilana"),
        ("\\bbaj(?:i|e)ya\\s+de\\s+lana\\b", "baje yaad dilana"),   // "Bajiya De Lana"
        ("\\bbaji\\b", "baje"),
        ("\\b(?:ek)\\s+(?=baje\\b)", "1 "), ("\\b(?:teen)\\s+(?=baje\\b)", "3 "), ("\\b(?:char|chaar)\\s+(?=baje\\b)", "4 "),
        ("\\b(?:paanch|panch)\\s+(?=baje\\b)", "5 "), ("\\b(?:che|chhe|chhah|chheh)\\s+(?=baje\\b)", "6 "),
        ("\\b(?:saat|sat)\\s+(?=baje\\b)", "7 "), ("\\b(?:aath|aat)\\s+(?=baje\\b)", "8 "), ("\\b(?:nau|now)\\s+(?=baje\\b)", "9 "),
        ("\\b(?:das|dus)\\s+(?=baje\\b)", "10 "), ("\\b(?:gyarah|gyara)\\s+(?=baje\\b)", "11 "), ("\\b(?:barah|bara)\\s+(?=baje\\b)", "12 "),
    ].map { (try! NSRegularExpression(pattern: $0.0, options: .caseInsensitive), $0.1) }

    public static func apply(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }
}

/// Small edit-distance helper for matching a misheard name to a known one.
public enum Fuzzy {
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = row[j]
                row[j] = cur
            }
        }
        return row[b.count]
    }

    /// The one known name within 1 edit (2 for names of 7+ letters) of `word`, or nil if none or several.
    /// Short names (under 4 letters) must match exactly: "mom" vs "tom" is a different person.
    public static func uniqueClose(_ word: String, in names: [String]) -> String? {
        let w = word.lowercased()
        guard w.count >= 4 else { return nil }
        let limit = w.count >= 7 ? 2 : 1
        let close = Set(names.map { $0.lowercased() }.filter { $0.count >= 4 && distance(w, $0) <= limit })
        return close.count == 1 ? close.first : nil
    }
}
