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
        try await qwen.startSession(system: system, maxTokens: maxTokens)
    }
}

/// A ChatSession over the loaded MLX model. Each `respond` only processes the new prompt.
final class QwenSession: BrainSession {
    private let session: ChatSession
    private let qwen: QwenPlanner

    init(session: ChatSession, qwen: QwenPlanner) {
        self.session = session
        self.qwen = qwen
    }

    func respond(_ prompt: String) async throws -> String {
        var reply = ""
        for try await item in session.streamDetails(to: prompt) {
            switch item {
            case .chunk(let s): reply += s
            case .info(let info):
                // Where the time goes: reading the prompt, or writing the reply.
                Log.agent.notice("model: \(info.promptTokenCount) prompt tokens in \(Int(info.promptTime * 1000)) ms, \(info.generationTokenCount) reply tokens in \(Int(info.generateTime * 1000)) ms (\(Int(Double(info.generationTokenCount) / max(0.001, info.generateTime))) tok/s)")
            default: break
            }
        }
        await qwen.touch()
        return reply
    }
}

/// Sends the whole exchange each time; Ollama and LM Studio cache the shared prefix themselves.
final class EndpointSession: BrainSession {
    private let brain: EndpointBrain
    private var messages: [[String: String]]
    private let maxTokens: Int

    init(brain: EndpointBrain, system: String, maxTokens: Int) {
        self.brain = brain
        self.messages = [["role": "system", "content": system]]
        self.maxTokens = maxTokens
    }

    func respond(_ prompt: String) async throws -> String {
        messages.append(["role": "user", "content": prompt])
        let reply = try await brain.chat(messages: messages, maxTokens: maxTokens)
        messages.append(["role": "assistant", "content": reply])
        return reply
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
        let reply = try await startSession(system: system, maxTokens: maxTokens).respond(prompt)
        return reply
    }

    /// A multi-turn session for one task. Deterministic (temperature 0, thinking off); bigger
    /// prefill chunks make long screens faster to read.
    func startSession(system: String, maxTokens: Int) async throws -> QwenSession {
        let container = try await load()
        var params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        params.prefillStepSize = 1024
        let session = ChatSession(container, instructions: system, generateParameters: params, additionalContext: ["enable_thinking": false])
        return QwenSession(session: session, qwen: self)
    }
}
