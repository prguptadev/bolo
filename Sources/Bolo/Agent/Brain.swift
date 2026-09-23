import BoloCore
import Foundation
import MLXLMCommon

/// Something that answers a prompt: Bolo's own MLX model (Qwen by default; `brainModel` in settings
/// picks a bigger one), or a local server such as Ollama or LM Studio (`agentBrain` = "endpoint")
/// for models Bolo can't load itself. Everything stays on this Mac.
protocol Brain: Sendable {
    var name: String { get }
    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String
}

struct QwenBrain: Brain {
    let qwen: QwenPlanner
    var name: String { "Qwen (local)" }

    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await qwen.respond(system: system, prompt: prompt, maxTokens: maxTokens)
    }
}

/// POST {base}/chat/completions, the OpenAI-style call that Ollama (http://localhost:11434/v1) and
/// LM Studio (http://localhost:1234/v1) answer. No key: it's your own machine.
struct EndpointBrain: Brain {
    let baseURL: String
    let model: String
    var name: String { "\(model) via \(URL(string: baseURL)?.host ?? baseURL)" }

    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String {
        guard let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions") else {
            throw SkillError.failed("Bad endpoint address in settings: \(baseURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            let text = String(decoding: data.prefix(300), as: UTF8.self)
            throw SkillError.failed("The local model server answered \(status): \(text)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw SkillError.failed("The local model server sent no reply text.") }
        return content
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension QwenPlanner {
    /// A single system + user exchange, for the agent loop.
    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String {
        let container = try await load()
        let session = ChatSession(
            container, instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let reply = try await session.respond(to: prompt)
        touch()
        return reply
    }
}
