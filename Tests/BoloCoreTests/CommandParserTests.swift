import Foundation
import Testing
@testable import BoloCore

private let parser = CommandParser(
    knownNames: ["bhai", "priya", "priya sharma", "mom", "rahul"],
    knownApps: ["notes", "microsoft teams", "whatsapp", "google chrome", "safari", "slack", "intellij idea"])

private func one(_ s: String) -> Step? {
    guard let c = parser.parse(s), c.steps.count == 1 else { return nil }
    return c.steps[0]
}

@Suite struct Messaging {
    @Test func hinglishWhatsApp() {
        let s = one("bhai ko WhatsApp karo, I'll be late by 20 minutes.")
        #expect(s == Step(.sendMessage, contact: "bhai", channel: .whatsapp, text: "I'll be late by 20 minutes"))
    }

    @Test func hinglishMessageKiDefaultChannel() {
        let s = one("bhai ko message bhejo ki main late hoon")
        #expect(s == Step(.sendMessage, contact: "bhai", channel: nil, text: "main late hoon"))
    }

    @Test func hinglishTeamsPe() {
        let s = one("Priya ko teams pe message karo joining in 5")
        #expect(s == Step(.sendMessage, contact: "Priya", channel: .teams, text: "joining in 5"))
    }

    @Test func hinglishMessageBeforeVerb() {
        let s = one("bhai ko main 10 minute mein aa raha hoon bol do")
        #expect(s == Step(.sendMessage, contact: "bhai", channel: nil, text: "main 10 minute mein aa raha hoon"))
    }

    @Test func likhoIsDraftNotSend() {
        let s = one("mom ko whatsapp pe likho dinner at 8 is fine")
        #expect(s?.action == .draftMessage)
        #expect(s?.text == "dinner at 8 is fine")
    }

    @Test func englishTeamsWithSaying() {
        let s = one("send a teams message to Priya saying joining in 5")
        #expect(s == Step(.sendMessage, contact: "Priya", channel: .teams, text: "joining in 5"))
    }

    @Test func englishNoSeparatorUsesKnownName() {
        let s = one("whatsapp priya sharma see you at 6")
        #expect(s == Step(.sendMessage, contact: "priya sharma", channel: .whatsapp, text: "see you at 6"))
    }

    @Test func messageOnChannel() {
        let s = one("send a message to Priya on Teams saying the build is green")
        #expect(s == Step(.sendMessage, contact: "Priya", channel: .teams, text: "the build is green"))
    }

    @Test func colonBecomesSaying() {
        let s = one("Teams Priya: joining in 5")
        #expect(s == Step(.sendMessage, contact: "Priya", channel: .teams, text: "joining in 5"))
    }

    @Test func openChatOnly() {
        let s = one("open bhai's whatsapp chat")
        #expect(s == Step(.draftMessage, contact: "bhai", channel: .whatsapp))
    }

    @Test func openChatAndSend() {
        let s = one("open whatsapp chat with mom and send reached home")
        #expect(s == Step(.sendMessage, contact: "mom", channel: .whatsapp, text: "reached home"))
    }

    @Test func andInsideMessageStaysInMessage() {
        let c = parser.parse("whatsapp bhai saying bring milk and call me when you reach")
        #expect(c?.steps.count == 1)
        #expect(c?.steps.first?.text == "bring milk and call me when you reach")
    }

    @Test func openUnknownAppInsideMessageStaysInMessage() {
        let c = parser.parse("tell bhai to bring milk and open the door")
        #expect(c?.steps.count == 1)
        #expect(c?.steps.first?.text == "to bring milk and open the door")
    }

    @Test func teamsCall() {
        #expect(one("teams call Priya") == Step(.call, contact: "Priya", channel: .teams))
        #expect(one("call priya on teams") == Step(.call, contact: "priya", channel: .teams))
    }
}

@Suite struct Everyday {
    @Test func openApps() {
        #expect(one("open notes") == Step(.openApp, app: "Notes"))
        #expect(one("open teams") == Step(.openApp, app: "Microsoft Teams"))
        #expect(one("Chrome kholo") == Step(.openApp, app: "Google Chrome"))
        #expect(one("hey bolo open intellij please") == Step(.openApp, app: "IntelliJ IDEA"))
    }

    @Test func unknownAppIsNotGuessed() {
        #expect(parser.parse("open the door") == nil)
    }

    @Test func urls() {
        #expect(one("open github dot com") == Step(.openURL, text: "github.com"))
    }

    @Test func notes() {
        #expect(one("new note groceries milk eggs bread") == Step(.newNote, text: "groceries milk eggs bread"))
        #expect(one("note down the demo is on Friday") == Step(.newNote, text: "the demo is on Friday"))
    }

    @Test func reminders() {
        let a = one("remind me at 5 pm to call bhai")
        #expect(a?.action == .addReminder)
        #expect(a?.text == "call bhai")
        #expect(a?.time != nil)
        let b = one("remind me to check the build in 10 minutes")
        #expect(b?.text == "check the build")
    }

    @Test func search() {
        #expect(one("search youtube for G1GC tuning") == Step(.webSearch, text: "G1GC tuning", engine: .youtube))
        #expect(one("google jvm heap dump analysis") == Step(.webSearch, text: "jvm heap dump analysis", engine: .google))
        #expect(one("play lofi beats on youtube") == Step(.webSearch, text: "lofi beats", engine: .youtube))
    }

    @Test func system() {
        #expect(one("volume 30") == Step(.setVolume, number: 30))
        #expect(one("mute") == Step(.mute))
        #expect(one("lock the screen") == Step(.lockScreen))
        #expect(one("join my next meeting") == Step(.joinNextMeeting))
        #expect(one("run my standup shortcut") == Step(.runShortcut, text: "standup"))
    }

    @Test func typing() {
        #expect(one("type thanks will review today") == Step(.typeText, text: "thanks will review today"))
    }
}

@Suite struct MultiStep {
    @Test func messageAndReminder() {
        let c = parser.parse("send a teams message to Priya saying joining in 5 and remind me at 5 pm to call her")
        #expect(c?.steps.count == 2)
        #expect(c?.steps[0] == Step(.sendMessage, contact: "Priya", channel: .teams, text: "joining in 5"))
        #expect(c?.steps[1].action == .addReminder)
        #expect(c?.steps[1].text == "call her")
    }

    @Test func openThenMessage() {
        let c = parser.parse("open teams and then bhai ko whatsapp karo on my way")
        #expect(c?.steps.map(\.action) == [.openApp, .sendMessage])
    }
}

@Suite struct GroundingTests {
    @Test func rejectsInventedMessage() {
        // What Apple's model actually produced for this utterance during testing.
        let c = Command(
            utterance: "new note groceries milk eggs bread",
            steps: [
                Step(.newNote, text: "groceries milk eggs bread"),
                Step(.sendMessage, contact: "Priya", channel: .whatsapp, text: "Hey Priya, I need to add some groceries"),
            ], source: .model)
        #expect(Grounding.filter(c) == nil)
    }

    @Test func keepsGroundedSteps() {
        let c = Command(
            utterance: "tell priya on teams I'm running late",
            steps: [Step(.sendMessage, contact: "priya", channel: .teams, text: "I'm running late")], source: .model)
        #expect(Grounding.filter(c)?.steps.count == 1)
    }

    @Test func dropsPaddingAndDuplicates() {
        let c = Command(
            utterance: "search youtube for G1GC tuning",
            steps: [
                Step(.webSearch, text: "G1GC tuning", engine: .youtube),
                Step(.webSearch, text: "G1GC tuning", engine: .youtube),
                Step(.webSearch, text: "how to tune a g1gc for better performance"),
            ], source: .model)
        #expect(Grounding.filter(c)?.steps.count == 1)
    }
}

extension Command: Equatable {
    public static func == (a: Command, b: Command) -> Bool { a.steps == b.steps && a.utterance == b.utterance }
}

@Suite struct Times {
    private let now = ISO8601DateFormatter().date(from: "2026-09-22T15:00:00+05:30")!

    @Test func relativeMinutes() {
        let d = TimePhrase.resolve("in 10 minutes", now: now)
        #expect(d == now.addingTimeInterval(600))
        #expect(TimePhrase.resolve("10 minute baad", now: now) == now.addingTimeInterval(600))
    }

    @Test func clockTimeLaterToday() {
        let d = TimePhrase.resolve("at 5 pm", now: now)!
        #expect(d > now)
        #expect(d.timeIntervalSince(now) < 3 * 3600)
    }

    @Test func pastClockTimeMeansTomorrow() {
        let d = TimePhrase.resolve("at 9 am", now: now)!
        #expect(d > now)
    }
}
