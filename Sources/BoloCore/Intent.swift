import Foundation

/// Tells "write this text" apart from "write something for me".
public enum Intent {
    private static let contentWords =
        "jokes?|poems?|poetry|shayari|story|stories|quotes?|e?-?mails?|letter|application|reply|response|summary|essay|speech|"
        + "wish|wishes|greeting|caption|tweet|post|list|ideas?|excuse|toast|limerick|riddle|fun fact|facts?|pickup line|compliment|"
        + "birthday message|thank you note|apology|"
        // Code and files are content too: the agent writes them as whole files.
        + "files?|programs?|class|function|method|scripts?|code|snippet|tests?|unit test|readme|config|sql|query|regex|component|module|"
        + "web ?page|website|html|css|json|yaml|dockerfile|makefile"

    private static let request = try! NSRegularExpression(
        // "a polite leave application": an article, up to three describing words, then the thing to write.
        pattern: "^(?:(?:a|an|one|two|three|some|ek|chhota sa)\\s+(?:[\\w'-]+\\s+){0,3}|(?:(?:small|short|funny|nice|good|quick|little|polite|formal|random|cute|sweet|sad|happy|new|simple|best|lovely)\\s+)+)?(?:" + contentWords + ")\\b",
        options: .caseInsensitive)

    /// "a one small joke for me", "a polite leave application", "some ideas for dinner" → true.
    /// "milk eggs bread", "the demo is on Friday" → false.
    public static func isContentRequest(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return request.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
}
