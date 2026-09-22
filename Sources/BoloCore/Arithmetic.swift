import Foundation

/// Spoken arithmetic: "5+5", "12 times 7", "18% of 2300", "100 divided by 8".
/// Only digits and operators ever reach NSExpression, so nothing else can be evaluated.
public enum Arithmetic {
    private static let words: [(String, String)] = [
        ("multiplied by", "*"), ("divided by", "/"), ("times", "*"), ("into", "*"), ("x", "*"), ("×", "*"),
        ("plus", "+"), ("and", "+"), ("minus", "-"), ("÷", "/"), ("over", "/"),
    ]

    /// "18% of 2300" → "(18/100)*2300"; nil if it isn't pure arithmetic.
    public static func expression(_ spoken: String) -> String? {
        var s = " " + spoken.lowercased().replacingOccurrences(of: ",", with: "") + " "
        s = s.replacingOccurrences(of: "(\\d+(?:\\.\\d+)?)\\s*(?:%|percent)\\s*of\\s*(\\d+(?:\\.\\d+)?)", with: "($1/100)*$2", options: .regularExpression)
        for (w, op) in words { s = s.replacingOccurrences(of: "\\s\\Q\(w)\\E\\s", with: " \(op) ", options: .regularExpression) }
        s = s.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !s.isEmpty, s.range(of: "^[-+*/().0-9]+$", options: .regularExpression) != nil,
            s.range(of: "\\d", options: .regularExpression) != nil,
            s.range(of: "[-+*/]", options: .regularExpression) != nil,
            // Shapes NSExpression can't parse would raise an Objective-C exception (a crash): reject them.
            s.range(of: "[-+*/]{2,}|^[*/]|[-+*/]$|\\(\\)|\\)\\(|\\d\\(|\\)\\d|\\.\\d*\\.|\\([*/)]|[-+*/]\\)", options: .regularExpression) == nil
        else { return nil }
        let opens = s.filter { $0 == "(" }.count, closes = s.filter { $0 == ")" }.count
        return opens == closes ? s : nil
    }

    public static func evaluate(_ spoken: String) -> Double? {
        guard let e = expression(spoken) else { return nil }
        // Decimals everywhere so 7/2 is 3.5, not 3.
        let floats = e.replacingOccurrences(of: "(?<![\\d.])(\\d+)(?![\\d.])", with: "$1.0", options: .regularExpression)
        guard let value = NSExpression(format: floats).expressionValue(with: nil, context: nil) as? NSNumber else { return nil }
        let d = value.doubleValue
        return d.isFinite ? d : nil
    }

    public static func format(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(format: "%.4g", d)
    }
}
