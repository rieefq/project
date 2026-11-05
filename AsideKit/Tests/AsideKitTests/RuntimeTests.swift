import Foundation
import Testing
@testable import AsideKit

@MainActor
struct Harness {
    let runtime: AgentRuntime
    let input: FakeSpeechInput
    let output: FakeSpeechOutput
    let earcons: FakeEarcons
    let reminders: FakeReminders
    let communication: FakeCommunication
    let clock: ManualClock
    let memory: MemoryStore

    init(reasoner: (any Reasoner)? = nil, preferences: Preferences = Preferences(), contacts: [ContactMatch]? = nil) {
        input = FakeSpeechInput()
        output = FakeSpeechOutput()
        earcons = FakeEarcons()
        reminders = FakeReminders()
        communication = FakeCommunication()
        clock = ManualClock(referenceNow)
        memory = MemoryStore(store: nil)
        let preferenceStore = PreferencesStore(store: nil, initial: preferences)
        let people = contacts ?? [ContactMatch(id: "c1", name: "Sam Lee", handles: [ContactHandle(kind: .phone, value: "+1 555 0100")])]
        let services = AsideServices(reminders: reminders, calendar: FakeCalendar(), notifications: FakeScheduler(),
                                     music: [FakeMusic(provider: .appleMusic)], contacts: FakeContacts(people), communication: communication)
        let assembly = Toolbox.assemble(services: services, memory: memory, preferences: preferenceStore, store: nil)
        let engine = ActionEngine(registry: assembly.registry, journal: ActionJournal(store: nil), authenticator: FakeAuthenticator())
        assembly.engineHandle.engine = engine
        let dependencies = AgentDependencies(
            speechInput: input, speechOutput: output, earcons: earcons, engine: engine, memory: memory, preferences: preferenceStore,
            reasoner: reasoner, localModel: nil, music: assembly.music, clock: clock,
            temporal: { testTemporal }, device: { DeviceContext(platform: .macOS) })
        runtime = AgentRuntime(dependencies: dependencies)
    }

    /// Push-to-talk: hold, say something, release.
    func say(_ text: String) async {
        runtime.activate(source: .pushToTalk)
        _ = await eventually { input.handler != nil && runtime.phase == .listening }
        input.say(text)
        runtime.pushToTalkEnded()
    }

    /// Answer a question Aside asked (endpointing decides when the answer is over).
    func answer(_ text: String) async {
        _ = await eventually { runtime.phase == .waiting }
        input.say(text)
        clock.advance(by: 2)
    }

    func heard(_ text: String) async -> Bool {
        await eventually { output.spoken.contains(text) }
    }
}

@Suite("Conversations", .serialized)
@MainActor
struct RuntimeTests {
    @Test func remindsInThirtyDaysAndGoesQuiet() async {
        let h = Harness()
        await h.say("Remind me to change my toothbrush in 30 days")
        #expect(await h.heard("Okay, I'll remind you to change your toothbrush on December 5th."))
        #expect(await h.reminders.items.first?.due == date(2026, 12, 5, 14, 30))
        #expect(await eventually { h.runtime.phase == .idle && !h.runtime.isMicrophoneActive })
        #expect(h.earcons.played.contains(.listening))
        #expect(h.earcons.played.contains(.success))
    }

    @Test func correctionsApplyToWhatWasJustDone() async {
        let h = Harness()
        await h.say("remind me to call mom at 5")
        #expect(await h.heard("Okay, I'll remind you to call mom at 5 PM."))
        _ = await eventually { h.runtime.phase == .idle }
        await h.say("change it to tomorrow")
        #expect(await h.heard("Okay, moved it to tomorrow at 5 PM."))
        #expect(await h.reminders.items.first?.due == date(2026, 11, 6, 17, 0))
    }

    @Test func correctionToAWeekdayReadsNaturally() async {
        let h = Harness()
        await h.say("Remind me to change my toothbrush in 30 days")
        #expect(await h.heard("Okay, I'll remind you to change your toothbrush on December 5th."))
        _ = await eventually { h.runtime.phase == .idle }
        await h.say("Actually, make it Saturday morning.")
        #expect(await h.heard("Okay, moved it to Saturday at 9 AM."))
        #expect(await h.reminders.items.first?.due == date(2026, 11, 7, 9, 0))
    }

    @Test func cancelThatUndoes() async {
        let h = Harness()
        await h.say("remind me to buy milk")
        #expect(await h.heard("Added \u{201C}Buy milk\u{201D} to your reminders."))
        _ = await eventually { h.runtime.phase == .idle }
        await h.say("cancel that")
        #expect(await h.heard("Okay, I removed that reminder."))
        #expect(await h.reminders.items.isEmpty)
    }

    @Test func messagesGoThroughTheSystemSheet() async {
        let h = Harness()
        await h.say("Text Sam Lee saying I'm running late")
        #expect(await h.heard("Sent to Sam Lee."))
        #expect(await h.communication.composed.first?.body == "I'm running late")
    }

    @Test func asksWhichContactAndUnderstandsTheAnswer() async {
        let h = Harness(contacts: [
            ContactMatch(id: "c1", name: "Sam Lee", handles: [ContactHandle(kind: .phone, value: "+1 555 0100")]),
            ContactMatch(id: "c2", name: "Sam Patel", handles: [ContactHandle(kind: .phone, value: "+1 555 0101")]),
        ])
        await h.say("text Sam saying hi")
        #expect(await h.heard("Which Sam — Sam Lee or Sam Patel?"))
        #expect(h.runtime.cards.contains { if case .choice = $0 { return true } else { return false } })
        await h.answer("the second one")
        #expect(await h.heard("Sent to Sam Patel."))
        #expect(await h.communication.composed.first?.recipient.name == "Sam Patel")
    }

    @Test func stopInterruptsSpeech() async {
        let h = Harness()
        h.output.holdUntilStopped = true
        await h.say("what time is it")
        #expect(await h.heard("It's 2:30 PM."))
        #expect(await eventually { h.runtime.phase == .speaking })
        h.input.say("stop")
        #expect(await eventually { h.output.stops > 0 && h.runtime.phase == .idle })
    }

    @Test func openQuestionsGoToTheCloudModel() async {
        let reasoner = ScriptedReasoner(script: [(nil, "Paris.")])
        let h = Harness(reasoner: reasoner)
        await h.say("what's the capital of France")
        #expect(await h.heard("Paris."))
        #expect(await reasoner.turns == ["what's the capital of France"])
    }

    @Test func cloudToolCallsAreGovernedLocally() async {
        let call = ToolCall(name: "send_message", arguments: ["recipient": "Sam Lee", "body": "On my way"], origin: .cloudModel)
        let reasoner = ScriptedReasoner(script: [(call, "")])
        let h = Harness(reasoner: reasoner)
        await h.say("let Sam know I'm on my way")
        #expect(await h.heard("Sent to Sam Lee."))
        let outcome = await reasoner.lastOutcome
        #expect(outcome?.isCompleted == true)
    }

    @Test func offlineFallsBackHonestly() async {
        var preferences = Preferences()
        preferences.reasoningMode = .onDeviceOnly
        let h = Harness(preferences: preferences)
        await h.say("what's the capital of France")
        #expect(await h.heard("I can't do that on this device yet."))
    }

    @Test func siriTextPathReturnsTheReply() async {
        let h = Harness()
        let reply = await h.runtime.submit(text: "set a timer for 5 minutes")
        #expect(reply == "5 minutes, starting now.")
        #expect(h.output.spoken.isEmpty)
    }

    @Test func discreetModeShowsInsteadOfSpeaking() async {
        var preferences = Preferences()
        preferences.speechPrivacy = .discreet
        let h = Harness(preferences: preferences)
        await h.say("what time is it")
        #expect(await eventually { h.runtime.replyCaption == "It's 2:30 PM." })
        #expect(h.output.spoken.isEmpty)
    }
}
