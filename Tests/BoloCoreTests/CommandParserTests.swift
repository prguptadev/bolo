import Foundation
import Testing
@testable import BoloCore

private let parser = CommandParser(
    knownNames: ["bhai", "priya", "priya sharma", "mom", "rahul"],
    knownApps: ["notes", "microsoft teams", "whatsapp", "google chrome", "safari", "slack", "intellij idea", "calendar", "calculator"])

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

    @Test func bataoMeansTell() {
        let s = one("priya ko teams pe batao ki build green hai")
        #expect(s == Step(.sendMessage, contact: "priya", channel: .teams, text: "build green hai"))
    }

    @Test func modelMessageLosesJoiningWord() {
        let steps = ModelOutput.steps(fromJSON: #"{"steps":[{"action":"sendMessage","contact":"priya","channel":"teams","text":"ki build green hai"}]}"#)
        #expect(steps.first?.text == "build green hai")
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

    @Test func hinglishSearch() {
        #expect(one("google karo spring boot actuator") == Step(.webSearch, text: "spring boot actuator", engine: .google))
        #expect(one("kotlin coroutines youtube pe search karo") == nil || one("kotlin coroutines youtube pe search karo")?.action == .webSearch)
        let c = parser.parse("Chrome kholo aur google karo spring boot actuator")
        #expect(c?.steps.map(\.action) == [.openApp, .webSearch])
        #expect(c?.steps.last?.text == "spring boot actuator")
    }

    @Test func requestsToTheAssistantAreNotMessages() {
        #expect(parser.parse("tell me a joke") == nil)
        #expect(parser.parse("tell us the time") == nil)
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

@Suite struct Hearing {
    @Test func hinglishMishearingsAreRepaired() {
        #expect(HearingFixes.apply("Bye ko WhatsApp Carol I'll be late") == "bhai ko WhatsApp karo I'll be late")
        #expect(HearingFixes.apply("Chrome cholo") == "Chrome kholo")
        #expect(HearingFixes.apply("mom ko message bejo ki main aa gaya") == "mom ko message bhejo ki main aa gaya")
        #expect(HearingFixes.apply("mujhe 6 baje yard dilana ki gym jaana hai") == "mujhe 6 baje yaad dilana ki gym jaana hai")
    }

    @Test func messageTextIsLeftAlone() {
        // "what's up" and "by" inside a message must survive.
        let s = "whatsapp bhai saying what's up bro, back by 6"
        #expect(HearingFixes.apply(s) == s)
    }

    @Test func alternativesAreTriedInOrder() {
        let r = parser.parse(candidates: ["by go what's up caro later", "bhai ko whatsapp karo on my way"])
        #expect(r?.index == 1)
        #expect(r?.command.steps.first == Step(.sendMessage, contact: "bhai", channel: .whatsapp, text: "on my way"))
    }

    @Test func fixedBestGuessWinsOverAlternatives() {
        let r = parser.parse(candidates: ["Bye ko WhatsApp Carol on my way", "buy coffee"])
        #expect(r?.index == 0)
        #expect(r?.command.steps.first?.contact == "bhai")
    }

    @Test func fuzzyNamesOnlyWhenUnique() {
        #expect(Fuzzy.uniqueClose("pria", in: ["priya", "rahul", "mom"]) == "priya")
        #expect(Fuzzy.uniqueClose("rahull", in: ["priya", "rahul"]) == "rahul")
        #expect(Fuzzy.uniqueClose("rahool", in: ["priya", "rahul"]) == nil)    // 2 edits on a short name: too far
        #expect(Fuzzy.uniqueClose("tom", in: ["mom"]) == nil)            // short names must match exactly
        #expect(Fuzzy.uniqueClose("amit", in: ["amir", "amita"]) == nil)  // two candidates: no guess
    }

    @Test func modelMayNotSendCallOrType() {
        let c = Command(utterance: "jot down call the plumber tomorrow",
                        steps: [Step(.call, contact: "plumber"), Step(.sendMessage, contact: "bhai", text: "hi")], source: .model)
        #expect(Grounding.limitModel(c)?.steps == [Step(.draftMessage, contact: "bhai", text: "hi")])
    }
}

/// Transcripts Apple's recognizer produced for the 50 recorded prompts (eval/recordings, 2026-09-22).
@Suite struct RecordedTranscripts {
    private func first(_ heard: String) -> Step? { parser.parse(candidates: [heard])?.command.steps.first }
    private func all(_ heard: String) -> [Action]? { parser.parse(candidates: [heard])?.command.steps.map(\.action) }

    @Test func teamSingular() {
        #expect(first("Priya Ko, Team Pe message Karo joining in five minutes.") == Step(.sendMessage, contact: "Priya", channel: .teams, text: "joining in five minutes"))
        #expect(first("Send a team message to Priya, saying the build is green.") == Step(.sendMessage, contact: "Priya", channel: .teams, text: "the build is green"))
        #expect(first("Team call Priya.") == Step(.call, contact: "Priya", channel: .teams))
    }

    @Test func hinglishWithCommasEverywhere() {
        #expect(first("Bhai Ko, WhatsApp Kar Do, I'll be late by 20 minutes.") == Step(.sendMessage, contact: "Bhai", channel: .whatsapp, text: "I'll be late by 20 minutes"))
        #expect(first("Mom, Ko, message, Bhejo, Mein, Ghar, Ponj Gya.")?.contact == "Mom")
        #expect(first("Papa Ko, Bol, Do, Main, Das, Minute, Mein, Ara, Hoon.")?.action == .sendMessage)
        #expect(first("Mom, Ko, WhatsApp Pe Niko, dinner at eight is fine.")?.action == .draftMessage)
        #expect(first("Bhai, Ko, call Karo teams, Pe") == Step(.call, contact: "Bhai", channel: .teams))
    }

    @Test func droppedAndBecomesTwoSteps() {
        #expect(all("Send a team message to Priya, saying joining in five minutes, remind me at 5 PM to call her.") == [.sendMessage, .addReminder])
        #expect(all("Chrome, Kholo, or Google, Karo, spring boot actuator.") == [.openApp, .webSearch])
        #expect(all("Open teams, and then Bhai Ko, WhatsApp Karo, on my way.") == [.openApp, .sendMessage])
    }

    @Test func misheardWords() {
        #expect(first("Open Intelligent.") == Step(.openApp, app: "IntelliJ IDEA"))
        #expect(first("Open get up.com") == Step(.openURL, text: "github.com"))
        #expect(first("WhatsApp be saying bring milk and call me when you reach.")?.contact == "bhai")
        #expect(first("Notes down demo is on Friday.") == Step(.newNote, text: "demo is on Friday"))
        #expect(first("Playing Lofi beat on YouTube?") == Step(.webSearch, text: "Lofi beat", engine: .youtube))
        #expect(first("Joining my next meeting?") == Step(.joinNextMeeting))
    }

    @Test func volumeWording() {
        #expect(first("Volume up to 30") == Step(.setVolume, number: 30))
        #expect(first("Turn the volume to 20.") == Step(.setVolume, number: 20))
        #expect(first("turn the volume down to 20") == Step(.setVolume, number: 20))
    }

    @Test func remindersInOtherWords() {
        let hindi = first("Mujhe, Che, Baji, Ya, De, Lana, Ki, Jim, Jana Hai?")
        #expect(hindi?.action == .addReminder)
        #expect(hindi?.text == "Jim Jana Hai")
        #expect(hindi?.time == "6 baje")
        let forget = first("Don't let me forget to pay the electricity bill at 7 PM.")
        #expect(forget?.action == .addReminder)
        #expect(forget?.text == "pay the electricity bill")
    }

    @Test func yourWhatsAppSentences() {
        // Exactly what Bolo heard on 2026-09-22.
        let a = parser.parse(candidates: ["Open WhatsApp and send message to  Aku.  I hate  you."])?.command
        #expect(a?.steps == [Step(.sendMessage, contact: "Aku", channel: .whatsapp, text: "I hate you")])
        let b = parser.parse(candidates: ["Now, can  you write a message to  Aku  on WhatsApp?  I love  you."])?.command
        #expect(b?.steps == [Step(.draftMessage, contact: "Aku", channel: .whatsapp, text: "I love you")])
        #expect(parser.parse(candidates: ["Can  you  open WhatsApp?"])?.command.steps == [Step(.openApp, app: "WhatsApp")])
    }

    @Test func fullStopBeforeACommandStillSplits() {
        #expect(parser.parse("Open notes. Remind me at 5 pm to call bhai")?.steps.map(\.action) == [.openApp, .addReminder])
    }

    @Test func sameNameDifferentSpelling() {
        #expect(Fuzzy.soundKey("Aku") == Fuzzy.soundKey("akku"))
        #expect(Fuzzy.soundKey("AAKU") == Fuzzy.soundKey("akku"))
        #expect(Fuzzy.soundKey("Vasu") == Fuzzy.soundKey("vashu"))
        #expect(Fuzzy.soundKey("Bhavya") == Fuzzy.soundKey("Bavya"))
        #expect(Fuzzy.soundKey("mom") != Fuzzy.soundKey("tom"))
        #expect(Fuzzy.soundKey("Priya") != Fuzzy.soundKey("Piya"))
    }

    @Test func liveTestSentences() {
        let orCorrection = parser.parse(candidates: ["Open WhatsApp and send message to  Vasu or  send message to  Akku, bye-bye."])?.command
        #expect(orCorrection?.steps == [Step(.sendMessage, contact: "Akku", channel: .whatsapp, text: "bye-bye")])
        let twice = parser.parse(candidates: ["Open WhatsApp and send message to  AAKU  Aku,  bye-bye."])?.command
        #expect(twice?.steps == [Step(.sendMessage, contact: "AAKU", channel: .whatsapp, text: "bye-bye")])
        let calc = parser.parse(candidates: ["Open calculator and add 5+5"])?.command
        #expect(calc?.steps == [Step(.openApp, app: "Calculator"), Step(.calculate, text: "5+5")])
        #expect(parser.parse(candidates: ["Can you open calculator and give me sum of 5+5?"])?.command.steps.last == Step(.calculate, text: "5+5"))
    }

    @Test func typingAfterOpeningAChatAppIsAMessage() {
        let p = CommandParser(knownNames: ["prashant gupta", "prashant", "akku"], knownApps: ["whatsapp", "microsoft teams"])
        let c = p.parse(candidates: ["Open WhatsApp and type Prashant Gupta, bye-bye."])?.command
        #expect(c?.steps == [Step(.draftMessage, contact: "Prashant Gupta", channel: .whatsapp, text: "bye-bye")])
        // Unknown first words: don't guess a recipient, and don't type into the open chat either.
        #expect(p.parse(candidates: ["Open WhatsApp and type see you tomorrow"]) == nil)
    }

    @Test func arithmetic() {
        #expect(Arithmetic.evaluate("5+5") == 10)
        #expect(Arithmetic.evaluate("12 times 7") == 84)
        #expect(Arithmetic.evaluate("18% of 2300") == 414)
        #expect(Arithmetic.evaluate("7 divided by 2") == 3.5)
        #expect(Arithmetic.evaluate("(5)(5)") == nil)     // would crash NSExpression; rejected
        #expect(Arithmetic.evaluate("rm -rf") == nil)
        #expect(Arithmetic.format(10) == "10")
    }

    @Test func bajiyaDeLana() {
        let s = first("Mujhe, Che, Bajiya, De Lana, Ki, Jim,  Jana Hai.")
        #expect(s?.action == .addReminder)
        #expect(s?.time == "6 baje")
    }

    @Test func moreEnglishPhrasings() {
        #expect(first("Could you pull up my calendar?") == Step(.openApp, app: "Calendar"))
        #expect(first("Let Priya know on teams that deployment is done.") == Step(.sendMessage, contact: "Priya", channel: .teams, text: "deployment is done"))
    }

    @Test func openChatAndSendIsOneCommand() {
        let c = parser.parse(candidates: ["Open WhatsApp chat with mom and send a message to reach home."])?.command
        #expect(c?.steps.count == 1)
        #expect(c?.steps.first?.contact == "mom")
        #expect(c?.steps.first?.action == .sendMessage)
    }

    @Test func unsureSendsBecomeDrafts() {
        let send = Command(utterance: "x", steps: [Step(.sendMessage, contact: "Mom", text: "Mein Ghar Ponj Gya"), Step(.call, contact: "Mom")], source: .rules)
        let low = SendPolicy.apply(send, confidence: 0.45, minConfidence: 0.6, usedAlternative: false)
        #expect(low.command.steps == [Step(.draftMessage, contact: "Mom", text: "Mein Ghar Ponj Gya")])
        #expect(low.reason != nil)
        let alt = SendPolicy.apply(send, confidence: 0.95, minConfidence: 0.6, usedAlternative: true)
        #expect(alt.command.steps.first?.action == .draftMessage)
        let sure = SendPolicy.apply(send, confidence: 0.9, minConfidence: 0.6, usedAlternative: false)
        #expect(sure.command.steps.count == 2)
        #expect(sure.reason == nil)
    }

    @Test func nonCommandsStayNonCommands() {
        #expect(parser.parse(candidates: ["I was thinking about the message bye later."]) == nil)
        #expect(parser.parse(candidates: ["Tell me a joke?"]) == nil)
        #expect(parser.parse(candidates: ["What's the weather like?"]) == nil)
    }

    @Test func bajeTimes() {
        let now = ISO8601DateFormatter().date(from: "2026-09-22T15:00:00+05:30")!
        let six = TimePhrase.resolve("6 baje", now: now)!
        #expect(six.timeIntervalSince(now) == 3 * 3600)   // 6 pm today, not 6 am
        let nine = TimePhrase.resolve("9 baje", now: now)!
        #expect(nine.timeIntervalSince(now) == 6 * 3600)  // 9 pm today
    }
}

@Suite struct ScreenCommands {
    @Test func clicks() {
        #expect(one("click send") == Step(.click, target: "send"))
        #expect(one("click on the Export button") == Step(.click, target: "Export"))
        #expect(one("tap the family group") == Step(.click, target: "family group"))
        #expect(one("Save pe click karo") == Step(.click, target: "Save"))
        #expect(one("submit dabao") == Step(.click, target: "submit"))
    }

    @Test func keysAndShortcuts() {
        #expect(one("press enter") == Step(.pressKey, text: "return"))
        #expect(one("press command shift t") == Step(.pressKey, text: "cmd+shift+t"))
        #expect(one("press cmd s") == Step(.pressKey, text: "cmd+s"))
        #expect(one("enter dabao") == Step(.pressKey, text: "return"))
        #expect(one("select all") == Step(.pressKey, text: "cmd+a"))
        #expect(one("copy that") == Step(.pressKey, text: "cmd+c"))
        #expect(one("save karo") == Step(.pressKey, text: "cmd+s"))
        #expect(one("open a new tab") == Step(.pressKey, text: "cmd+t"))
        #expect(one("press send") == Step(.click, target: "send"))  // not a key: a button
    }

    @Test func menus() {
        #expect(one("File menu export as PDF") == Step(.menu, target: "File > export as PDF"))
        #expect(one("choose Make Plain Text from the Format menu") == Step(.menu, target: "Format > Make Plain Text"))
        #expect(one("menu show sidebar") == Step(.menu, target: "show sidebar"))
        #expect(one("File, export as PDF") == Step(.menu, target: "File > export as PDF"))
        #expect(one("view my calendar") == nil || one("view my calendar")?.action != .menu)
    }

    @Test func scrollingAndBack() {
        #expect(one("scroll down") == Step(.scroll, text: "down"))
        #expect(one("scroll up 3 times") == Step(.scroll, text: "up", number: 3))
        #expect(one("scroll to the bottom") == Step(.scroll, text: "bottom"))
        #expect(one("neeche scroll karo") == Step(.scroll, text: "down"))
        #expect(one("go back") == Step(.goBack))
    }

    @Test func typingIntoFields() {
        #expect(one("type hello world in the search box") == Step(.typeInto, text: "hello world", target: "search"))
        #expect(one("type jvm tuning in search") == Step(.typeInto, text: "jvm tuning", target: "search"))
        // No field word: it's plain typing, even with "in the" inside
        #expect(one("type I'll be in the office") == Step(.typeText, text: "I'll be in the office"))
    }

    @Test func chatsByName() {
        #expect(one("open the family group on whatsapp") == Step(.draftMessage, contact: "family", channel: .whatsapp))
        #expect(one("open design team chat on slack") == Step(.draftMessage, contact: "design team", channel: .slack))
    }

    @Test func clicksInsideMessagesStayInTheMessage() {
        let c = parser.parse("whatsapp bhai saying please click the link and press submit")
        #expect(c?.steps.count == 1)
        #expect(c?.steps.first?.text == "please click the link and press submit")
    }

    @Test func appThenClick() {
        #expect(parser.parse("open calculator and click 7")?.steps.map(\.action) == [.openApp, .click])
    }

    @Test func screenMatching() {
        #expect(ScreenMatch.score(said: "export as pdf", label: "Export as PDF…") == 1)
        #expect(ScreenMatch.score(said: "export", label: "Export as PDF…") == 0.9)
        #expect(ScreenMatch.score(said: "send", label: "Sender settings and privacy options") < 0.8)
        let labels = ["Save", "Save As…", "Send"]
        if case .found(let l) = ScreenMatch.best("save", in: labels, label: { $0 }) { #expect(l == "Save") } else { Issue.record("expected Save") }
        if case .ambiguous = ScreenMatch.best("family", in: ["Family", "family"], label: { $0 }) { Issue.record("same label twice is one thing") }
        if case .ambiguous = ScreenMatch.best("design", in: ["Design team", "Design review"], label: { $0 }) {} else { Issue.record("two different matches must be ambiguous") }
    }

    @Test func keyCombos() {
        #expect(KeyCombo.canonical("shift command t") == "cmd+shift+t")
        #expect(KeyCombo.canonical("escape") == "escape")
        #expect(KeyCombo.canonical("control option delete") == "ctrl+opt+delete")
        #expect(KeyCombo.canonical("the door") == nil)
    }

    @Test func modelScreenActionsMustBeGrounded() {
        let c = Command(utterance: "click the export button",
                        steps: [Step(.click, target: "Export"), Step(.pressKey, text: "return")], source: .qwen)
        #expect(Grounding.filter(c)?.steps == [Step(.click, target: "Export")])  // Return wasn't said
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
