import Foundation
import FoundationModels

/// Fallback for sentences the phrase parser can't read: Apple's on-device model fills a fixed
/// schema, then `Grounding` throws away anything the user didn't say.
///
/// The schema is built by hand with `DynamicGenerationSchema` because the `@Generable` macro
/// plugin ships only with Xcode, and this project builds with the command-line tools.
public final class ModelPlanner: @unchecked Sendable {
    public enum PlannerError: Error { case unavailable(String) }

    private static let actions = [
        "openApp", "openURL", "sendMessage", "draftMessage", "call", "newNote", "addReminder",
        "webSearch", "joinNextMeeting", "typeText", "setVolume", "mute", "unmute", "lockScreen",
    ]

    private static let instructions = """
        You convert one spoken command for a Mac into steps. Rules:
        - Use one step per thing the user asked for. Most commands are one step.
        - Copy contact names and message text exactly from the user's words. Never invent them.
        - Use an empty string for any field the user didn't give.
        - sendMessage means send; draftMessage means only open the chat and type.
        Examples:
        "open slack" -> openApp app=Slack
        "tell priya on teams I'm running late" -> sendMessage contact=priya channel=teams text=I'm running late
        "note that the demo is on friday" -> newNote text=the demo is on friday
        """

    private let schema: GenerationSchema

    public init() throws {
        let string = DynamicGenerationSchema(type: String.self)
        let step = DynamicGenerationSchema(
            name: "Step",
            properties: [
                .init(name: "action", schema: .init(name: "Action", anyOf: Self.actions)),
                .init(name: "app", description: "App to open, else empty", schema: string),
                .init(name: "contact", description: "Person, exactly as the user said it, else empty", schema: string),
                .init(
                    name: "channel", description: "Messaging app the user named",
                    schema: .init(name: "Channel", anyOf: ["whatsapp", "teams", "imessage", "slack", "mail", "none"])),
                .init(name: "text", description: "Message, note, reminder, search query or URL in the user's words", schema: string),
                .init(name: "time", description: "Reminder time as spoken, else empty", schema: string),
                .init(name: "number", description: "Volume percent, else empty", schema: string),
            ])
        let plan = DynamicGenerationSchema(
            name: "Plan",
            properties: [
                .init(name: "steps", schema: .init(arrayOf: .init(referenceTo: "Step"), minimumElements: 1, maximumElements: 3))
            ])
        schema = try GenerationSchema(root: plan, dependencies: [step])
    }

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func plan(_ utterance: String) async throws -> Command? {
        guard Self.isAvailable else { throw PlannerError.unavailable("\(SystemLanguageModel.default.availability)") }
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: utterance, schema: schema, options: GenerationOptions(temperature: 0))
        let raw = try JSONDecoder().decode(RawPlan.self, from: Data(response.content.jsonString.utf8))
        let steps = raw.steps.compactMap { $0.step }
        return Grounding.filter(Command(utterance: utterance, steps: steps, source: .model))
    }

    private struct RawPlan: Decodable { var steps: [RawStep] }

    private struct RawStep: Decodable {
        var action: String
        var app: String?
        var contact: String?
        var channel: String?
        var text: String?
        var time: String?
        var number: String?

        var step: Step? {
            guard let action = Action(rawValue: action) else { return nil }
            func v(_ s: String?) -> String? {
                guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "none" else { return nil }
                return s
            }
            return Step(
                action, app: v(app).map(AppNames.canonical), contact: v(contact),
                channel: v(channel).flatMap(Channel.from(spoken:)), text: v(text), time: v(time),
                engine: (v(text) ?? "").lowercased().contains("youtube") ? .youtube : .google,
                number: v(number).flatMap { Int($0.filter(\.isNumber)) })
        }
    }
}
