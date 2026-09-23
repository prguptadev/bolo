import BoloCore
import Foundation
import MLXLMCommon

/// Something that answers a prompt: Bolo's own MLX model (Qwen by default; `brainModel` in settings
/// picks a bigger one), or a local server such as Ollama or LM Studio (`agentBrain` = "endpoint")
/// for models Bolo can't load itself. Everything stays on this Mac.
protocol Brain: Sendable {
    var name: String { get }
    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String
    /// A conversation for one task: the system prompt and earlier turns stay cached.
    func startTask(system: String, maxTokens: Int) async throws -> BrainSession
}

protocol BrainSession: AnyObject {
    func respond(_ prompt: String) async throws -> String
}

struct QwenBrain: Brain {
    let qwen: QwenPlanner
    var name: String { "\(QwenPlanner.modelID.split(separator: "/").last ?? "MLX") (local)" }

    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await qwen.respond(system: system, prompt: prompt, maxTokens: maxTokens)
    }

    func startTask(system: String, maxTokens: Int) async throws -> BrainSession {
        try await qwen.load()
        return QwenSession(qwen: qwen, system: system, maxTokens: maxTokens)
    }
}

/// Each step is answered from the cached system prompt plus that step's own text.
final class QwenSession: BrainSession {
    private let qwen: QwenPlanner
    private let system: String
    private let maxTokens: Int

    init(qwen: QwenPlanner, system: String, maxTokens: Int) {
        self.qwen = qwen
        self.system = system
        self.maxTokens = maxTokens
    }

    func respond(_ prompt: String) async throws -> String {
        try await qwen.respondCached(system: system, prompt: prompt, maxTokens: maxTokens)
    }
}

/// Ollama and LM Studio cache the system prompt themselves.
final class EndpointSession: BrainSession {
    private let brain: EndpointBrain
    private let system: String
    private let maxTokens: Int

    init(brain: EndpointBrain, system: String, maxTokens: Int) {
        self.brain = brain
        self.system = system
        self.maxTokens = maxTokens
    }

    func respond(_ prompt: String) async throws -> String {
        try await brain.chat(messages: [["role": "system", "content": system], ["role": "user", "content": prompt]], maxTokens: maxTokens)
    }
}

/// POST {base}/chat/completions, the OpenAI-style call that Ollama (http://localhost:11434/v1) and
/// LM Studio (http://localhost:1234/v1) answer. No key: it's your own machine.
struct EndpointBrain: Brain {
    let baseURL: String
    let model: String
    var name: String { "\(model) via \(URL(string: baseURL)?.host ?? baseURL)" }

    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await chat(messages: [["role": "system", "content": system], ["role": "user", "content": prompt]], maxTokens: maxTokens)
    }

    func startTask(system: String, maxTokens: Int) async throws -> BrainSession {
        EndpointSession(brain: self, system: system, maxTokens: maxTokens)
    }

    func chat(messages: [[String: String]], maxTokens: Int) async throws -> String {
        guard let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "chat/completions" : baseURL + "/chat/completions") else {
            throw SkillError.failed("Bad endpoint address in settings: \(baseURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "temperature": 0, "max_tokens": maxTokens, "messages": messages]
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
    /// A single system + user exchange.
    func respond(system: String, prompt: String, maxTokens: Int) async throws -> String {
        try await respondCached(system: system, prompt: prompt, maxTokens: maxTokens)
    }
}
