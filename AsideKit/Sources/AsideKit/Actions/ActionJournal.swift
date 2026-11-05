import Foundation

/// One thing Aside did, tried to do, or was asked to do.
public struct JournalEntry: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable, Hashable {
        case completed, failed, declined, awaitingConfirmation, undone, deduplicated
    }

    public var id: String
    public var date: Date
    public var toolName: String
    public var capability: Capability
    public var origin: CallOrigin
    public var status: Status
    /// Plain-language summary ("Created reminder “Change toothbrush” for Dec 5, 9:00").
    public var summary: String
    public var undo: UndoPlan?
    public var referent: Referent?
    public var idempotencyKey: String
    public var turnID: String?
    public var failure: String?

    public init(id: String = Identifier.make("act"), date: Date, toolName: String, capability: Capability, origin: CallOrigin,
                status: Status, summary: String, undo: UndoPlan? = nil, referent: Referent? = nil, idempotencyKey: String,
                turnID: String?, failure: String? = nil) {
        self.id = id
        self.date = date
        self.toolName = toolName
        self.capability = capability
        self.origin = origin
        self.status = status
        self.summary = summary
        self.undo = undo
        self.referent = referent
        self.idempotencyKey = idempotencyKey
        self.turnID = turnID
        self.failure = failure
    }

    public var isUndoable: Bool { status == .completed && undo != nil }
}

/// Append-only record of actions, kept on device for a limited time.
///
/// It powers "what did you just do?", "undo that", corrections, failure explanations
/// and the on-demand Activity view. It stores summaries, not raw audio or transcripts.
public actor ActionJournal {
    private let store: PersistentStore?
    private let key = "journal.v1"
    private var entries: [JournalEntry] = []
    private var loaded = false
    private var retentionDays: Int
    private let maximumEntries = 500

    public init(store: PersistentStore?, retentionDays: Int = 30) {
        self.store = store
        self.retentionDays = retentionDays
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let store, let data = try? await store.load(key),
              let decoded = try? StoreCoding.decoder().decode([JournalEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() async {
        guard let store, let data = try? StoreCoding.encoder().encode(entries) else { return }
        try? await store.save(data, for: key)
    }

    public func setRetention(days: Int) async {
        retentionDays = max(1, days)
        await prune(now: Date())
    }

    @discardableResult
    public func record(_ entry: JournalEntry) async -> JournalEntry {
        await ensureLoaded()
        entries.append(entry)
        await prune(now: entry.date)
        await persist()
        return entry
    }

    public func update(_ id: String, status: JournalEntry.Status) async {
        await ensureLoaded()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        await persist()
    }

    public func recent(limit: Int = 50) async -> [JournalEntry] {
        await ensureLoaded()
        return Array(entries.suffix(limit).reversed())
    }

    public func entries(since date: Date) async -> [JournalEntry] {
        await ensureLoaded()
        return entries.filter { $0.date >= date }
    }

    /// The most recent completed action that can be undone, if recent enough.
    public func lastUndoable(before now: Date, within window: TimeInterval) async -> JournalEntry? {
        await ensureLoaded()
        return entries.last { $0.isUndoable && now.timeIntervalSince($0.date) <= window }
    }

    /// The most recent completed action (for "what did you just do?").
    public func lastCompleted() async -> JournalEntry? {
        await ensureLoaded()
        return entries.last { $0.status == .completed || $0.status == .undone }
    }

    /// A completed entry with this key inside the window, used to avoid duplicate actions.
    public func completed(withKey key: String, after date: Date) async -> JournalEntry? {
        await ensureLoaded()
        return entries.last { $0.idempotencyKey == key && $0.status == .completed && $0.date >= date }
    }

    public func clear() async {
        entries.removeAll()
        loaded = true
        await persist()
    }

    public func exportJSON() async -> Data {
        await ensureLoaded()
        let encoder = StoreCoding.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(entries)) ?? Data("[]".utf8)
    }

    private func prune(now: Date) async {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        entries.removeAll { $0.date < cutoff }
        if entries.count > maximumEntries { entries.removeFirst(entries.count - maximumEntries) }
    }
}
