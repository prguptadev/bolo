import BoloCore
import Foundation

/// Looks things up on the web without an API key: weather (wttr.in), currency (open.er-api.com),
/// everything else from DuckDuckGo's HTML results, with Wikipedia as a fallback. Returns short text
/// snippets plus where they came from; Qwen turns them into an answer.
enum WebLookup {
    struct Result {
        let snippets: [String]
        let source: String
        /// Already a complete answer (weather, currency): no summarising needed.
        let direct: String?
    }

    static func search(_ query: String) async throws -> Result {
        let q = query.lowercased()
        if q.range(of: "\\b(weather|temperature|mausam|forecast|rain|barish)\\b", options: .regularExpression) != nil {
            return try await weather(place: place(in: query))
        }
        if let conversion = try? await currency(query) { return conversion }
        if let ddg = try? await duckDuckGo(query), !ddg.snippets.isEmpty { return ddg }
        return try await wikipedia(query)
    }

    // MARK: Weather

    /// "weather in Pune" → "Pune"; nothing → wttr.in guesses from your IP.
    private static func place(in query: String) -> String {
        guard let r = query.range(of: "\\b(?:in|at|for|of)\\s+([A-Za-z][A-Za-z .-]{1,40})", options: .regularExpression) else { return "" }
        return String(query[r]).replacingOccurrences(of: "^(?:in|at|for|of)\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+(today|tomorrow|now|right now|kaisa hai|kya hai)$", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func weather(place: String) async throws -> Result {
        let path = place.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://wttr.in/\(path)?format=%25l:+%25C,+%25t+(feels+like+%25f),+humidity+%25h,+wind+%25w") else {
            throw SkillError.failed("Couldn't ask for the weather.")
        }
        let text = try await get(url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.lowercased().contains("unknown location") else { throw SkillError.failed("No weather for \(place).") }
        return Result(snippets: [text], source: "wttr.in", direct: text)
    }

    // MARK: Currency

    private static let codes: [String: String] = [
        "dollar": "USD", "dollars": "USD", "usd": "USD", "rupee": "INR", "rupees": "INR", "inr": "INR", "euro": "EUR",
        "euros": "EUR", "eur": "EUR", "pound": "GBP", "pounds": "GBP", "gbp": "GBP", "yen": "JPY", "dirham": "AED",
        "dirhams": "AED", "aed": "AED", "singapore dollar": "SGD", "sgd": "SGD",
    ]

    /// "1 dollar in rupees", "100 usd to inr".
    private static func currency(_ query: String) async throws -> Result? {
        let pattern = "([\\d.]+)?\\s*([a-z ]+?)\\s+(?:in|to|into|me)\\s+([a-z ]+?)(?:\\?|$|\\s+kitna|\\s+how much)"
        guard let m = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            .firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
            let fromR = Range(m.range(at: 2), in: query), let toR = Range(m.range(at: 3), in: query)
        else { return nil }
        let amount = Range(m.range(at: 1), in: query).flatMap { Double(query[$0]) } ?? 1
        let fromWord = String(query[fromR]).lowercased().replacingOccurrences(of: "^(?:what is|what's|how much is|convert)\\s+", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard let from = codes[fromWord] ?? codes[String(fromWord.split(separator: " ").last ?? "")],
            let to = codes[String(query[toR]).lowercased().trimmingCharacters(in: .whitespaces)]
        else { return nil }
        guard let rateURL = URL(string: "https://open.er-api.com/v6/latest/\(from)") else { return nil }
        let data = try await getData(rateURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rates = json["rates"] as? [String: Double], let rate = rates[to]
        else { return nil }
        let value = amount * rate
        let text = "\(Arithmetic.format(amount)) \(from) = \(String(format: "%.2f", value)) \(to)"
        return Result(snippets: [text], source: "open.er-api.com", direct: text)
    }

    // MARK: DuckDuckGo

    private static func duckDuckGo(_ query: String) async throws -> Result {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(q)") else { throw SkillError.failed("Bad search.") }
        let html = try await get(url)
        let titles = matches(in: html, "class=\"result__a\"[^>]*>(.*?)</a>")
        let snippets = matches(in: html, "class=\"result__snippet\"[^>]*>(.*?)</a>")
        let urls = matches(in: html, "class=\"result__url\"[^>]*>\\s*(.*?)\\s*</a>")
        let combined = zip(titles, snippets).prefix(5).map { "\($0.0): \($0.1)" }
        return Result(snippets: combined, source: urls.first.map { clean($0) } ?? "DuckDuckGo", direct: nil)
    }

    // MARK: Wikipedia

    private static func wikipedia(_ query: String) async throws -> Result {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srlimit=3&format=json&srsearch=\(q)") else {
            throw SkillError.failed("Bad search.")
        }
        let data = try await getData(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = (json["query"] as? [String: Any])?["search"] as? [[String: Any]], !results.isEmpty
        else { throw SkillError.failed("Couldn't find anything for \"\(query)\".") }
        let snippets = results.compactMap { r -> String? in
            guard let title = r["title"] as? String, let snippet = r["snippet"] as? String else { return nil }
            return "\(title): \(clean(snippet))"
        }
        return Result(snippets: snippets, source: "Wikipedia", direct: nil)
    }

    // MARK: HTTP and HTML

    private static func getData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-IN,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw SkillError.failed("The web didn't answer (\(url.host ?? "")).") }
        return data
    }

    private static func get(_ url: URL) async throws -> String {
        String(decoding: try await getData(url), as: UTF8.self)
    }

    private static func matches(in s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { clean(String(s[$0])) }
        }
    }

    static func clean(_ html: String) -> String {
        var t = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}
