import Foundation
import Testing
@testable import AsideKit

@Suite("Fast path grammar")
struct FastPathTests {
    let parser = FastPathParser()

    func call(_ text: String) -> (name: String, arguments: JSONValue)? {
        guard case .call(let name, let arguments, _)? = parser.parse(Utterance(text)) else { return nil }
        return (name, arguments)
    }

    @Test func remindersInEitherOrder() {
        let a = call("Remind me to change my toothbrush in 30 days")
        #expect(a?.name == "create_reminder")
        #expect(a?.arguments["title"]?.stringValue == "change my toothbrush")
        #expect(a?.arguments["when"]?.stringValue == "in 30 days")

        let b = call("remind me in thirty days to change my toothbrush")
        #expect(b?.arguments["title"]?.stringValue == "change my toothbrush")
        #expect(b?.arguments["when"]?.stringValue == "in thirty days")

        let c = call("Hey Aside, can you remind me tomorrow at 9 to call the dentist")
        #expect(c?.arguments["title"]?.stringValue == "call the dentist")
        #expect(c?.arguments["when"]?.stringValue == "tomorrow at 9")

        let d = call("remind me to buy milk")
        #expect(d?.arguments["title"]?.stringValue == "buy milk")
        #expect(d?.arguments["when"] == nil)

        let e = call("remind me that I need to call Sam on Friday")
        #expect(e?.arguments["title"]?.stringValue == "call Sam")
        #expect(e?.arguments["when"]?.stringValue == "on Friday")
    }

    @Test func reminderQueriesAndCompletion() {
        #expect(call("what are my reminders for today")?.name == "list_reminders")
        #expect(call("what are my reminders for today")?.arguments["when"]?.stringValue == "for today")
        #expect(call("mark buy milk as done")?.arguments["search"]?.stringValue == "buy milk")
    }

    @Test func timers() {
        let a = call("set a timer for 10 minutes")
        #expect(a?.name == "start_timer")
        #expect(a?.arguments["seconds"]?.doubleValue == 600)
        let b = call("10 minute pasta timer")
        #expect(b?.arguments["seconds"]?.doubleValue == 600)
        #expect(b?.arguments["label"]?.stringValue == "pasta")
        #expect(call("how much time is left on my timer")?.name == "list_timers")
        #expect(call("cancel the timer")?.name == "cancel_timer")
    }

    @Test func calendar() {
        #expect(call("What's on my schedule tomorrow?")?.arguments["when"]?.stringValue == "tomorrow")
        #expect(call("what's on my calendar")?.name == "get_schedule")
        #expect(call("when is my next meeting")?.arguments["next"]?.boolValue == true)
        #expect(call("am I free tomorrow afternoon")?.arguments["availability"]?.boolValue == true)
        let event = call("add lunch with Sam to my calendar on Friday at noon")
        #expect(event?.name == "create_event")
        #expect(event?.arguments["title"]?.stringValue == "lunch with Sam")
        #expect(event?.arguments["when"]?.stringValue == "on Friday at noon")
    }

    @Test func music() {
        let a = call("Play Blinding Lights on Spotify")
        #expect(a?.name == "play_music")
        #expect(a?.arguments["query"]?.stringValue == "Blinding Lights")
        #expect(a?.arguments["provider"]?.stringValue == "spotify")
        #expect(call("play the album Rumours")?.arguments["kind"]?.stringValue == "album")
        #expect(call("pause")?.arguments["action"]?.stringValue == "pause")
        #expect(call("skip this song")?.arguments["action"]?.stringValue == "next")
    }

    @Test func weatherTimeMath() {
        let weather = call("what's the weather in Paris tomorrow")
        #expect(weather?.name == "get_weather")
        #expect(weather?.arguments["place"]?.stringValue == "Paris")
        #expect(weather?.arguments["when"]?.stringValue == "tomorrow")
        #expect(call("is it going to rain tomorrow")?.arguments["focus"]?.stringValue == "precipitation")
        #expect(call("what time is it in Tokyo")?.arguments["place"]?.stringValue == "Tokyo")
        #expect(call("what's 18% of 64")?.name == "calculate")
        #expect(call("convert 5 km to miles")?.name == "calculate")
    }

    @Test func messagesAndCalls() {
        let a = call("Text Sam I'm running late")
        #expect(a?.name == "send_message")
        #expect(a?.arguments["recipient"]?.stringValue == "Sam")
        #expect(a?.arguments["body"]?.stringValue == "I'm running late")
        let b = call("text mom saying I'll be there at 6")
        #expect(b?.arguments["recipient"]?.stringValue == "mom")
        #expect(b?.arguments["body"]?.stringValue == "I'll be there at 6")
        #expect(call("call mom")?.name == "call_contact")
        #expect(call("call me Rif")?.name == "set_preference")
        #expect(call("tell me a joke") == nil)
    }

    @Test func memory() {
        let note = call("note that the gate code is 4412")
        #expect(note?.name == "save_note")
        #expect(note?.arguments["text"]?.stringValue == "the gate code is 4412")
        let fact = call("remember that Alex is allergic to peanuts")
        #expect(fact?.arguments["kind"]?.stringValue == "fact")
        #expect(call("remember to buy milk")?.name == "create_reminder")
        #expect(call("what's my gate code")?.name == "recall")
        #expect(call("forget everything")?.arguments["all"]?.boolValue == true)
    }

    @Test func placesAndHonestAlternatives() {
        #expect(call("directions to the airport")?.arguments["destination"]?.stringValue == "airport")
        #expect(call("how long to get to SFO")?.name == "get_travel_time")
        guard case .offer(_, let name, _)? = parser.parse(Utterance("wake me up at 7")) else {
            Issue.record("expected an offer"); return
        }
        #expect(name == "create_reminder")
    }

    @Test func leavesOpenQuestionsToModels() {
        #expect(parser.parse(Utterance("what's the capital of France")) == nil)
        #expect(parser.parse(Utterance("why is the sky blue")) == nil)
        #expect(parser.parse(Utterance("help me plan a trip to Lisbon")) == nil)
    }
}

@Suite("Control and answers")
struct ControlTests {
    @Test func controlCommands() {
        #expect(ControlCommandParser.parse(Utterance("Stop")) == .stop)
        #expect(ControlCommandParser.parse(Utterance("cancel that")) == .cancel)
        #expect(ControlCommandParser.parse(Utterance("never mind")) == .dismiss)
        #expect(ControlCommandParser.parse(Utterance("what are you doing?")) == .status)
        #expect(ControlCommandParser.parse(Utterance("undo that")) == .undo)
        #expect(ControlCommandParser.parse(Utterance("okay thanks")) == .done)
        #expect(ControlCommandParser.parse(Utterance("stop the music and play jazz")) == nil)
    }

    @Test func yesNoAndChoices() {
        #expect(AnswerParser.yesNo(Utterance("yes send it")) == .yes)
        #expect(AnswerParser.yesNo(Utterance("nope")) == .no)
        #expect(AnswerParser.yesNo(Utterance("tomorrow at 5")) == nil)
        let options = ["Sam Lee", "Sam Patel"]
        #expect(AnswerParser.choice(Utterance("the second one"), options: options) == 1)
        #expect(AnswerParser.choice(Utterance("Patel"), options: options) == 1)
        #expect(AnswerParser.choice(Utterance("Sam"), options: options) == nil)
        #expect(AnswerParser.choice(Utterance("the last one"), options: options) == 1)
    }

    @Test func corrections() {
        let reminder = Referent(kind: .reminder, id: "r1", title: "Call mom", date: referenceNow, hasTime: true)
        #expect(CorrectionParser.parse(Utterance("change it to tomorrow"), referent: reminder) == .reschedule(when: "tomorrow"))
        #expect(CorrectionParser.parse(Utterance("no, I said 3 PM"), referent: reminder) == .reschedule(when: "3 PM"))
        #expect(CorrectionParser.parse(Utterance("make it Friday instead"), referent: reminder) == .reschedule(when: "Friday"))
        #expect(CorrectionParser.parse(Utterance("rename it to call dad"), referent: reminder) == .retitle("call dad"))
        #expect(CorrectionParser.parse(Utterance("remind me to call mom tomorrow"), referent: reminder) == nil)
        let timer = Referent(kind: .timer, id: "t1", title: "timer")
        #expect(CorrectionParser.parse(Utterance("make it 20 minutes"), referent: timer) == .changeDuration(text: "20 minutes"))
    }
}

@Suite("Turn-taking")
struct TurnTakingTests {
    @Test func adaptiveSilence() {
        var endpointer = Endpointer(startedAt: referenceNow)
        endpointer.transcriptChanged("remind me to", at: referenceNow.addingTimeInterval(1))
        #expect(endpointer.requiredSilence == endpointer.configuration.danglingSilence)
        #expect(endpointer.decide(at: referenceNow.addingTimeInterval(2.0)) == .keepListening)
        #expect(endpointer.decide(at: referenceNow.addingTimeInterval(2.8)) == .endOfTurn)

        var complete = Endpointer(startedAt: referenceNow)
        complete.transcriptChanged("set a timer for 10 minutes", at: referenceNow.addingTimeInterval(1))
        complete.transcriptLooksComplete = true
        #expect(complete.decide(at: referenceNow.addingTimeInterval(1.6)) == .endOfTurn)
    }

    @Test func noSpeechTimesOutQuietly() {
        let endpointer = Endpointer(startedAt: referenceNow)
        #expect(endpointer.decide(at: referenceNow.addingTimeInterval(3)) == .keepListening)
        #expect(endpointer.decide(at: referenceNow.addingTimeInterval(7)) == .noSpeech)
    }

    @Test func voiceActivityHoldsTheTurnOpen() {
        var endpointer = Endpointer(startedAt: referenceNow)
        endpointer.transcriptChanged("what's the weather", at: referenceNow.addingTimeInterval(1))
        endpointer.voiceActivity(true, at: referenceNow.addingTimeInterval(1.5))
        #expect(endpointer.decide(at: referenceNow.addingTimeInterval(4)) == .keepListening)
    }

    @Test func echoIsNotAnInterruption() {
        var guardrail = EchoGuard()
        guardrail.speaking("Tomorrow you have three things: standup at 9 and lunch with Sam.")
        #expect(!guardrail.isGenuineInterruption("lunch with Sam"))
        #expect(guardrail.isGenuineInterruption("actually make it Friday"))
        #expect(guardrail.isGenuineInterruption("stop"))
    }
}
