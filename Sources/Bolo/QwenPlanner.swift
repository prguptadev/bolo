import BoloCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Qwen3.5-4B (4-bit, MLX, GPU): the fallback brain for sentences the phrase rules can't read.
/// Measured in eval/results/text-2026-09-22.md: 92% right intent, handles Hinglish, and with the
/// grounding guard, 0 unsafe sends (rules first, then Qwen: 96% fully right).
///
/// - Starts loading when you press the key (while you're still talking) and unloads after
///   `idleSeconds` without use, so its ~3.2 GB is held only while you're using Bolo.
/// - Deterministic (temperature 0, thinking off). Its JSON reply is parsed, then grounded.
actor QwenPlanner {
    static let defaultModelID = "mlx-community/Qwen3.5-4B-MLX-4bit"
    /// From `brainModel` in settings: any MLX text model on Hugging Face (Qwen3.5-9B-MLX-4bit is the
    /// sensible step up for agent work: ~5 GB, roughly twice as slow, noticeably better at planning).
    nonisolated(unsafe) static var modelID = defaultModelID

    private let idleSeconds: Double
    private var container: ModelContainer?
    private var loading: Task<ModelContainer, Error>?
    private var unloadTask: Task<Void, Never>?

    init(idleSeconds: Double) {
        self.idleSeconds = idleSeconds
    }

    /// Where the Hugging Face libraries cache the weights (same layout Python uses).
    static var cacheFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + modelID.replacingOccurrences(of: "/", with: "--"))
    }

    /// True once the ~3.1 GB of weights are on disk. Bolo never downloads them mid-command.
    static var isDownloaded: Bool {
        let snapshots = cacheFolder.appendingPathComponent("snapshots")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil) else { return false }
        return dirs.contains { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".safetensors") }
        }
    }

    /// Loads the model (downloading it first if needed). Safe to call repeatedly.
    @discardableResult
    func load() async throws -> ModelContainer {
        unloadTask?.cancel()
        if let container { return container }
        if let loading { return try await loading.value }
        let task = Task { () throws -> ModelContainer in
            let started = Date()
            let c = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(id: Self.modelID))
            Log.agent.notice("Qwen loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return c
        }
        loading = task
        defer { loading = nil }
        let c = try await task.value
        container = c
        scheduleUnload()
        return c
    }

    /// Used just now: keep it loaded a while longer.
    func touch() { scheduleUnload() }

    func unload() {
        container = nil
        MLX.Memory.clearCache()
        Log.agent.notice("Qwen unloaded")
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let seconds = idleSeconds
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func plan(_ utterance: String) async throws -> Command? {
        let container = try await load()
        let started = Date()
        // A fresh session per sentence: no memory of earlier commands.
        let session = ChatSession(
            container, instructions: Self.instructions,
            generateParameters: GenerateParameters(maxTokens: 400, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let json = try await session.respond(to: utterance)
        scheduleUnload()
        let steps = ModelOutput.steps(fromJSON: json)
        Log.agent.notice("Qwen \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(json, privacy: .public)")
        return Grounding.filter(Command(utterance: utterance, steps: steps, source: .qwen))
    }

    /// Short answer from web results, for `lookup`.
    func summarize(question: String, results: [String]) async throws -> String {
        let container = try await load()
        let session = ChatSession(
            container,
            instructions: """
                Answer the question in at most two short sentences using only the search results below.
                Keep numbers, names and dates exactly as written. If the results don't answer it, reply: I couldn't find that.
                """,
            generateParameters: GenerateParameters(maxTokens: 160, temperature: 0),
            additionalContext: ["enable_thinking": false])
        let prompt = "Question: \(question)\nSearch results:\n" + results.map { "- " + $0 }.joined(separator: "\n")
        let answer = try await session.respond(to: prompt)
        scheduleUnload()
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Do-commands keep the wording measured in eval/text_eval.py; write and ask were added after.
    static let instructions = """
        You are Bolo, a voice assistant on the user's Mac. Turn what they said into JSON. They speak English or Hinglish.
        Reply with only: {"steps": [ ... ]}.

        Three kinds of requests:
        1. DO something on the Mac: use the actions below. Copy contact names and message words exactly from the user. Never invent them.
        2. WRITE something for them (a joke, poem, email, reply, wish, list, ideas): write it yourself, short and good, in "text",
           and add "generated": true. Put it where they asked: newNote, draftMessage to the named person, or typeText.
           Match their language: Hinglish if they spoke Hinglish.
        3. ASK a question:
           - Facts that don't change (definitions, how-to, history, maths, general knowledge): {"action":"answer","text":"<one to three sentences>","generated":true}
           - Anything current (weather, news, prices, scores, exchange rates, today's events, anything after 2025): {"action":"lookup","text":"<a search query>"}
        If they aren't asking for anything, reply {"steps": []}.

        Each step has "action" and only the fields it needs:
        - openApp: app | openURL: text (the address) | webSearch: text, engine ("google" or "youtube") (only when they ask to search in the browser)
        - sendMessage / draftMessage: contact, text, channel (whatsapp, teams, imessage, mail) only if the user named the app
        - call: contact, channel | newNote: text | addReminder: text, time | typeText: text
        - setVolume: number | mute | unmute | lockScreen | joinNextMeeting | runShortcut: text
        - On-screen: click: target (the button, row, tab or link label) | menu: target ("File > Export as PDF")
          | typeInto: target (the field), text | scroll: text (up, down, top, bottom) | pressKey: text ("cmd+s", "return") | goBack
        - calculate: text (just the arithmetic, like "5+5" or "18% of 2300")
        - answer: text, generated | lookup: text
        - system: target (one of: emptyTrash, openTrash, openFolder, newFolder, ejectAll, sleep, restart, shutdown, logout,
          darkModeOn, darkModeOff, screenshot, brightnessUp, brightnessDown, wifiOn, wifiOff, keepAwake, stopKeepAwake,
          battery, diskSpace, ipAddress, time, date, clipboard, clearClipboard, quitApp, hideApp, minimize, fullScreen,
          showDesktop, missionControl, playPause, nextTrack, previousTrack), plus app (for quitApp/hideApp) or text (folder name, duration)
        Rules:
        - "send / message / tell / text" = sendMessage. "write / type / draft a message" = draftMessage (typed, not sent).
        - "open WhatsApp and type <name>, <text>" = draftMessage to <name>. Never use typeText for a message in a chat app;
          if no person is named, reply {"steps": []}.
        - Hinglish: "X ko ... karo / bhejo / bolo / bol do / batao" = sendMessage to X; "likho" = draftMessage; "yaad dilana" = addReminder; "kholo" = openApp.
        - One step per thing asked.
        Examples:
        "bhai ko WhatsApp karo I'll be late" -> {"steps":[{"action":"sendMessage","contact":"bhai","channel":"whatsapp","text":"I'll be late"}]}
        "open slack and remind me at 4 to review the PR" -> {"steps":[{"action":"openApp","app":"Slack"},{"action":"addReminder","text":"review the PR","time":"at 4"}]}
        "export this as a pdf from the file menu" -> {"steps":[{"action":"menu","target":"File > Export as PDF"}]}
        "in notes write a small joke for me" -> {"steps":[{"action":"newNote","text":"Why do programmers prefer dark mode? Because light attracts bugs.","generated":true}]}
        "what is the capital of Japan" -> {"steps":[{"action":"answer","text":"Tokyo.","generated":true}]}
        "weather in Pune today" -> {"steps":[{"action":"lookup","text":"weather in Pune"}]}
        "I was thinking about calling mom later" -> {"steps":[]}
        """
}
