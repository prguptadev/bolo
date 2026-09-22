import Foundation

/// Reads a model's JSON plan, `{"steps":[{"action":…, "app":…, "contact":…, …}]}`, into steps.
/// Shared by Apple's model and Qwen. Unknown actions and empty fields are dropped; app names are
/// canonicalised the same way the phrase parser does it.
public enum ModelOutput {
    public static func steps(fromJSON json: String) -> [Step] {
        guard let start = json.firstIndex(of: "{"), let end = json.lastIndex(of: "}"),
            let data = String(json[start...end]).data(using: .utf8),
            let plan = try? JSONDecoder().decode(RawPlan.self, from: data)
        else { return [] }
        return plan.steps.compactMap(\.step)
    }

    private struct RawPlan: Decodable { var steps: [RawStep] }

    /// Numbers arrive as 30 or "30" depending on the model.
    private struct Flexible: Decodable {
        var value: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { value = s }
            else if let i = try? c.decode(Int.self) { value = String(i) }
            else if let d = try? c.decode(Double.self) { value = String(Int(d)) }
        }
    }

    private struct RawStep: Decodable {
        var action: String
        var app, contact, channel, text, time, engine: String?
        var number: Flexible?

        var step: Step? {
            guard let action = Action(rawValue: action) else { return nil }
            func v(_ s: String?) -> String? {
                guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "none" else { return nil }
                return s
            }
            let engine: SearchEngine =
                v(self.engine)?.lowercased() == "youtube" || (v(text) ?? "").lowercased().contains("youtube") ? .youtube : .google
            // Models sometimes keep the Hinglish/English joining word: "ki build green hai".
            var text = v(text)
            if [.sendMessage, .draftMessage].contains(action), let t = text {
                text = t.replacingOccurrences(of: "^(?:ki|that|saying|ke)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            }
            return Step(
                action, app: v(app).map(AppNames.canonical), contact: v(contact),
                channel: v(channel).flatMap(Channel.from(spoken:)), text: text, time: v(time),
                engine: action == .webSearch ? engine : nil,
                number: v(number?.value).flatMap { Int($0.filter(\.isNumber)) })
        }
    }
}
