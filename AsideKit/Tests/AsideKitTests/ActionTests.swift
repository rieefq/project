import Foundation
import Testing
@testable import AsideKit

@Suite("Policy")
struct PolicyTests {
    let policy = PolicyEngine()
    let spec = ToolSpec(name: "x", description: "", inputSchema: [:], capability: .system, risk: .read)

    func prepared(_ risk: RiskTier, platformConfirms: Bool = false, minimum: ConfirmationStrength? = nil) -> PreparedCall {
        PreparedCall(call: ToolCall(name: "x", arguments: [:], origin: .fastPath), risk: risk,
                     confirmation: minimum.map { ConfirmationDetails(title: "t", consequence: "c", prompt: "p", minimumStrength: $0) },
                     platformConfirms: platformConfirms)
    }

    @Test func tiers() {
        #expect(policy.decide(prepared(.read), spec: spec, context: testContext()) == .allow)
        #expect(policy.decide(prepared(.reversible), spec: spec, context: testContext()) == .allow)
        #expect(policy.decide(prepared(.consequential), spec: spec, context: testContext()) == .confirm(.tap))
        #expect(policy.decide(prepared(.consequential, minimum: .deviceAuthentication), spec: spec, context: testContext()) == .confirm(.deviceAuthentication))
        #expect(policy.decide(prepared(.consequential, platformConfirms: true), spec: spec, context: testContext()) == .allow)
        if case .deny = policy.decide(prepared(.restricted), spec: spec, context: testContext()) {} else { Issue.record("restricted must be denied") }
    }

    @Test func voiceIsNeverEnoughForConsequentialActions() {
        #expect(policy.decide(prepared(.consequential, minimum: .voice), spec: spec, context: testContext()) == .confirm(.tap))
    }

    @Test func webContentTriggersAConfirmationForWrites() {
        var context = testContext(origin: .cloudModel)
        context.turnHasExternalContent = true
        #expect(policy.decide(prepared(.reversible), spec: spec, context: context) == .confirm(.voice))
    }
}

@Suite("Action engine")
struct EngineTests {
    func makeEngine(reminders: FakeReminders = FakeReminders(), authenticator: FakeAuthenticator = FakeAuthenticator()) -> (ActionEngine, MemoryStore) {
        let memory = MemoryStore(store: nil)
        let assembly = Toolbox.assemble(services: AsideServices(reminders: reminders, notifications: FakeScheduler()),
                                        memory: memory, preferences: PreferencesStore(store: nil, initial: Preferences()), store: nil)
        let engine = ActionEngine(registry: assembly.registry, journal: ActionJournal(store: nil), authenticator: authenticator)
        assembly.engineHandle.engine = engine
        return (engine, memory)
    }

    @Test func createsReminderWithGroundedDate() async {
        let reminders = FakeReminders()
        let (engine, _) = makeEngine(reminders: reminders)
        let call = ToolCall(name: "create_reminder", arguments: ["title": "change my toothbrush", "when": "in 30 days"], origin: .fastPath, turnID: "t1")
        let outcome = await engine.perform(call, context: testContext())
        guard case .completed(let result) = outcome else { Issue.record("expected completion, got \(outcome)"); return }
        #expect(result.speech.balanced == "Okay, I'll remind you to change your toothbrush on December 5th.")
        let items = await reminders.items
        #expect(items.count == 1)
        #expect(items.first?.title == "Change my toothbrush")
        #expect(items.first?.due == date(2026, 12, 5, 14, 30))
    }

    @Test func modelDatesAreUsedOnlyWhenWordsCantBeParsed() async {
        let reminders = FakeReminders()
        let (engine, _) = makeEngine(reminders: reminders)
        // The phrase wins over a wrong ISO date from a model.
        let call = ToolCall(name: "create_reminder", arguments: ["title": "pay rent", "when": "tomorrow at 9", "due_iso": "2026-11-09T09:00"], origin: .cloudModel)
        _ = await engine.perform(call, context: testContext(origin: .cloudModel))
        #expect(await reminders.items.first?.due == date(2026, 11, 6, 9, 0))
    }

    @Test func missingTitleAsksAQuestion() async {
        let (engine, _) = makeEngine()
        let outcome = await engine.perform(ToolCall(name: "create_reminder", arguments: ["when": "tomorrow"], origin: .fastPath), context: testContext())
        guard case .needsInfo(let slot) = outcome else { Issue.record("expected a question"); return }
        #expect(slot.parameter == "title")
    }

    @Test func pastTimesAreQuestionedNotSaved() async {
        let reminders = FakeReminders()
        let (engine, _) = makeEngine(reminders: reminders)
        let outcome = await engine.perform(ToolCall(name: "create_reminder", arguments: ["title": "x", "when": "today at 9am"], origin: .fastPath), context: testContext())
        guard case .needsInfo = outcome else { Issue.record("expected a question"); return }
        #expect(await reminders.items.isEmpty)
    }

    @Test func duplicatesWithinATurnAreNotRepeated() async {
        let reminders = FakeReminders()
        let (engine, _) = makeEngine(reminders: reminders)
        let call = ToolCall(name: "create_reminder", arguments: ["title": "buy milk"], origin: .cloudModel, turnID: "t1")
        _ = await engine.perform(call, context: testContext())
        let second = await engine.perform(ToolCall(name: "create_reminder", arguments: ["title": "buy milk"], origin: .cloudModel, turnID: "t1"), context: testContext())
        #expect(await reminders.items.count == 1)
        guard case .completed(let result) = second else { Issue.record("expected dedupe"); return }
        #expect(result.speech.balanced == "That's already done.")
    }

    @Test func undoReversesTheLastAction() async {
        let reminders = FakeReminders()
        let (engine, _) = makeEngine(reminders: reminders)
        _ = await engine.perform(ToolCall(name: "create_reminder", arguments: ["title": "buy milk"], origin: .fastPath), context: testContext())
        let undone = await engine.undoLast(context: testContext())
        guard case .completed(let result) = undone else { Issue.record("expected undo"); return }
        #expect(result.speech.balanced == "Okay, I removed that reminder.")
        #expect(await reminders.items.isEmpty)
        let journal = await engine.journal.recent()
        #expect(journal.contains { $0.status == .undone })
    }

    @Test func failuresAreReportedHonestly() async {
        let reminders = FakeReminders()
        await reminders.setFailNextCreate()
        let (engine, _) = makeEngine(reminders: reminders)
        let outcome = await engine.perform(ToolCall(name: "create_reminder", arguments: ["title": "buy milk"], origin: .fastPath), context: testContext())
        guard case .failed(let failure) = outcome else { Issue.record("expected failure"); return }
        #expect(failure.message == "I couldn't save that reminder.")
        #expect(await engine.journal.recent().first?.status == .failed)
    }

    @Test func missingPermissionIsExplained() async {
        let reminders = FakeReminders()
        await reminders.setState(.denied)
        let (engine, _) = makeEngine(reminders: reminders)
        let outcome = await engine.perform(ToolCall(name: "create_reminder", arguments: ["title": "x"], origin: .fastPath), context: testContext())
        guard case .needsPermission(let request) = outcome else { Issue.record("expected permission request"); return }
        #expect(request.capability == .reminders)
    }

    @Test func forgettingEverythingNeedsDeviceAuthentication() async {
        let authenticator = FakeAuthenticator()
        let (engine, memory) = makeEngine(authenticator: authenticator)
        await memory.add("The gate code is 4412", kind: .note, source: .explicit, now: referenceNow)
        let outcome = await engine.perform(ToolCall(name: "forget", arguments: ["all": true], origin: .fastPath), context: testContext())
        guard case .needsConfirmation(let request) = outcome else { Issue.record("expected confirmation"); return }
        #expect(request.strength == .deviceAuthentication)
        authenticator.answer = false
        let refused = await engine.confirm(request.id, now: referenceNow)
        guard case .failed = refused else { Issue.record("expected refusal"); return }
        #expect(await memory.all().count == 1)
    }
}

@Suite("Tools")
struct ToolTests {
    @Test func correctionKeepsTimeOfDay() async {
        let reminders = FakeReminders()
        let tool = UpdateReminderTool(service: reminders)
        let record = try? await reminders.create(ReminderDraft(title: "Call mom", due: date(2026, 11, 5, 17, 0), hasTime: true))
        let call = ToolCall(name: "update_reminder", arguments: ["id": .string(record!.id), "when": "tomorrow"], origin: .correction)
        let context = testContext(origin: .correction)
        guard case .ready(let prepared) = await tool.prepare(call, in: context) else { Issue.record("not ready"); return }
        let outcome = await tool.execute(prepared, in: context)
        guard case .completed(let result) = outcome else { Issue.record("expected completion"); return }
        #expect(await reminders.items.first?.due == date(2026, 11, 6, 17, 0))
        #expect(result.speech.balanced == "Okay, moved it to tomorrow at 5 PM.")
    }

    @Test func timersScheduleNotifications() async {
        let scheduler = FakeScheduler()
        let center = TimerCenter(scheduler: scheduler, store: nil)
        let tool = StartTimerTool(center: center)
        let call = ToolCall(name: "start_timer", arguments: ["duration": "10 minutes", "label": "pasta"], origin: .fastPath)
        guard case .ready(let prepared) = await tool.prepare(call, in: testContext()) else { Issue.record("not ready"); return }
        guard case .completed(let result) = await tool.execute(prepared, in: testContext()) else { Issue.record("not completed"); return }
        #expect(result.speech.balanced == "Pasta timer, 10 minutes.")
        let scheduled = await scheduler.scheduled
        #expect(scheduled.count == 1)
        #expect(scheduled.first?.fireDate == referenceNow.addingTimeInterval(600))
        #expect(scheduled.first?.body == "10 minutes — time's up.")
    }

    @Test func memoryRoundTrip() async {
        let memory = MemoryStore(store: nil)
        let save = SaveNoteTool(memory: memory)
        let call = ToolCall(name: "save_note", arguments: ["text": "I parked on level 3", "kind": "note", "user_asked": true], origin: .fastPath)
        guard case .ready(let prepared) = await save.prepare(call, in: testContext()) else { Issue.record("not ready"); return }
        _ = await save.execute(prepared, in: testContext())
        let recall = RecallTool(memory: memory)
        let outcome = await recall.execute(PreparedCall(call: ToolCall(name: "recall", arguments: ["query": "where did I park"], origin: .fastPath), risk: .read), in: testContext())
        guard case .completed(let result) = outcome else { Issue.record("expected recall"); return }
        #expect(result.speech.balanced == "You noted that you parked on level 3.")
    }

    @Test func inferredMemoriesNeedConsent() async {
        let memory = MemoryStore(store: nil)
        let save = SaveNoteTool(memory: memory)
        let call = ToolCall(name: "save_note", arguments: ["text": "Prefers window seats", "kind": "preference", "user_asked": true], origin: .cloudModel)
        // The model claims the user asked, but the user's words don't say so.
        guard case .ready(let prepared) = await save.prepare(call, in: testContext(origin: .cloudModel, utterance: "book me a flight to Denver")) else {
            Issue.record("not ready"); return
        }
        #expect(prepared.confirmation?.minimumStrength == .voice)
    }

    @Test func sensitiveMemoriesAreFlagged() async {
        let memory = MemoryStore(store: nil)
        let item = await memory.add("My bank PIN is 1234", kind: .note, source: .explicit, now: referenceNow)
        #expect(item.isSensitive)
        let context = await memory.context(for: "what's for dinner")
        #expect(!context.contains { $0.id == item.id })
    }

    @Test func memoryExportAndDelete() async throws {
        let memory = MemoryStore(store: nil)
        await memory.add("Alex is allergic to peanuts", kind: .fact, source: .explicit, now: referenceNow)
        let exported = await memory.exportJSON()
        let restored = MemoryStore(store: nil)
        let count = try await restored.importJSON(exported, now: referenceNow)
        #expect(count == 1)
        await memory.removeAll()
        #expect(await memory.all().isEmpty)
    }

    @Test func messagesUseTheSystemSheetAndNeverClaimSent() async {
        let contacts = FakeContacts([ContactMatch(id: "c1", name: "Sam Lee", handles: [ContactHandle(kind: .phone, value: "+1 555 0100", label: "mobile")]),
                                     ContactMatch(id: "c2", name: "Sam Patel", handles: [ContactHandle(kind: .phone, value: "+1 555 0101")])])
        let communication = FakeCommunication()
        await communication.setResult(.handedOff)
        let tool = SendMessageTool(contacts: contacts, communication: communication)
        let call = ToolCall(name: "send_message", arguments: ["recipient": "Sam", "body": "Running late"], origin: .fastPath)
        guard case .outcome(.needsChoice(let choice)) = await tool.prepare(call, in: testContext()) else { Issue.record("expected a choice"); return }
        #expect(choice.options.map(\.label) == ["Sam Lee", "Sam Patel"])
        let chosen = choice.call.with(choice.parameter, choice.options[0].value)
        guard case .ready(let prepared) = await tool.prepare(chosen, in: testContext()) else { Issue.record("not ready"); return }
        #expect(prepared.platformConfirms)
        guard case .completed(let result) = await tool.execute(prepared, in: testContext()) else { Issue.record("not completed"); return }
        #expect(result.speech.balanced == "Your message to Sam Lee is ready — just hit send.")
        #expect(await communication.composed.first?.body == "Running late")
    }

    @Test func scheduleReadsNaturally() async {
        let calendar = FakeCalendar(events: [
            EventRecord(id: "e1", title: "Standup", start: date(2026, 11, 6, 9), end: date(2026, 11, 6, 9, 15)),
            EventRecord(id: "e2", title: "Lunch with Sam", start: date(2026, 11, 6, 12), end: date(2026, 11, 6, 13)),
            EventRecord(id: "e3", title: "Dentist", start: date(2026, 11, 6, 16), end: date(2026, 11, 6, 17)),
        ])
        let tool = GetScheduleTool(service: calendar)
        let outcome = await tool.execute(PreparedCall(call: ToolCall(name: "get_schedule", arguments: ["when": "tomorrow"], origin: .fastPath), risk: .read),
                                         in: testContext())
        guard case .completed(let result) = outcome else { Issue.record("not completed"); return }
        #expect(result.speech.balanced == "Tomorrow you have three things: standup at 9 AM, lunch with Sam at noon, and dentist at 4 PM.")
        #expect(result.isPersonal)
    }
}

extension FakeCommunication {
    func setResult(_ value: ComposeResult) { result = value }
}
