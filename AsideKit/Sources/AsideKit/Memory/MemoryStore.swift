import Foundation

/// Something the user asked Aside to keep: a note, a fact, a preference.
public struct MemoryItem: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable, Hashable {
        /// "Note that the gate code is 4412."
        case note
        /// "Remember that Alex is allergic to peanuts."
        case fact
        /// "I prefer window seats." / "Use Spotify for music."
        case preference
        /// "I promised Sam I'd send the deck by Friday."
        case commitment

        public var displayName: String {
            switch self {
            case .note: return "Notes"
            case .fact: return "Facts"
            case .preference: return "Preferences"
            case .commitment: return "Commitments"
            }
        }
    }

    public enum Source: String, Sendable, Codable, Hashable {
        /// The user explicitly asked Aside to remember or note it.
        case explicit
        /// Aside asked and the user agreed.
        case confirmed
        /// Imported from an export file.
        case imported
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var source: Source
    public var isSensitive: Bool

    public init(id: String = Identifier.make("mem"), kind: Kind, text: String, createdAt: Date, source: Source, isSensitive: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.lastUsedAt = nil
        self.source = source
        self.isSensitive = isSensitive
    }
}

/// Lightweight keyword index used for on-device recall. Embeddings can replace it later
/// behind the same interface.
public enum TextIndex {
    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "to", "of", "and", "or", "in", "on", "at", "for", "with", "my",
        "me", "i", "you", "your", "that", "this", "it", "its", "what", "whats", "what's", "where", "when", "who", "how",
        "do", "does", "did", "remember", "note", "about", "from", "by", "as", "s", "am", "know", "tell", "please", "can",
        "could", "would", "should", "we", "our", "us", "they", "them", "there", "here", "have", "has", "had",
    ]

    public static func keywords(_ text: String) -> [String] {
        Utterance(text).norms
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
            .filter { !$0.isEmpty && !stopwords.contains($0) }
            .map(stem)
    }

    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        for suffix in ["ing", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static let sensitiveMarkers: [String] = [
        "password", "passcode", "pin", "code", "ssn", "social security", "account number", "card number", "routing",
        "diagnos", "medication", "prescription", "therapy", "therapist", "blood", "pregnan", "salary", "bank", "lock combination",
    ]

    public static func looksSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        return sensitiveMarkers.contains { lower.contains($0) }
    }
}

/// On-device store for everything Aside remembers. Fully reviewable, editable,
/// exportable and deletable by the user.
public actor MemoryStore {
    private let store: PersistentStore?
    private let key = "memory.v1"
    private var items: [MemoryItem] = []
    private var loaded = false

    public init(store: PersistentStore?) {
        self.store = store
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let store, let data = try? await store.load(key),
              let decoded = try? StoreCoding.decoder().decode([MemoryItem].self, from: data) else { return }
        items = decoded
    }

    private func persist() async {
        guard let store, let data = try? StoreCoding.encoder().encode(items) else { return }
        try? await store.save(data, for: key)
    }

    public func all() async -> [MemoryItem] {
        await ensureLoaded()
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func item(_ id: String) async -> MemoryItem? {
        await ensureLoaded()
        return items.first { $0.id == id }
    }

    /// Adds an item, or refreshes a near-duplicate instead of storing it twice.
    @discardableResult
    public func add(_ text: String, kind: MemoryItem.Kind, source: MemoryItem.Source, now: Date, sensitive: Bool? = nil) async -> MemoryItem {
        await ensureLoaded()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKeywords = Set(TextIndex.keywords(cleaned))
        if let index = items.firstIndex(where: { existing in
            let existingKeywords = Set(TextIndex.keywords(existing.text))
            guard !existingKeywords.isEmpty, !newKeywords.isEmpty else { return false }
            let overlap = Double(existingKeywords.intersection(newKeywords).count)
            return overlap / Double(max(existingKeywords.count, newKeywords.count)) >= 0.85
        }) {
            items[index].text = cleaned
            items[index].updatedAt = now
            await persist()
            return items[index]
        }
        let item = MemoryItem(kind: kind, text: cleaned, createdAt: now, source: source,
                              isSensitive: sensitive ?? TextIndex.looksSensitive(cleaned))
        items.append(item)
        await persist()
        return item
    }

    public func update(_ id: String, text: String, now: Date) async -> MemoryItem? {
        await ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].text = text
        items[index].updatedAt = now
        items[index].isSensitive = items[index].isSensitive || TextIndex.looksSensitive(text)
        await persist()
        return items[index]
    }

    @discardableResult
    public func remove(_ id: String) async -> MemoryItem? {
        await ensureLoaded()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        await persist()
        return removed
    }

    /// Restores a removed item (for undo).
    public func restore(_ item: MemoryItem) async {
        await ensureLoaded()
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        await persist()
    }

    public func removeAll() async {
        items.removeAll()
        loaded = true
        await persist()
    }

    public func markUsed(_ ids: [String], now: Date) async {
        await ensureLoaded()
        var changed = false
        for index in items.indices where ids.contains(items[index].id) {
            items[index].lastUsedAt = now
            changed = true
        }
        if changed { await persist() }
    }

    /// Ranked keyword search.
    ///
    /// The score is the fraction of the query's keywords found in an item (0…1), with a
    /// small BM25 and recency component to order items that match equally well.
    public func search(_ query: String, limit: Int = 5, now: Date = Date()) async -> [(item: MemoryItem, score: Double)] {
        await ensureLoaded()
        let terms = Array(Set(TextIndex.keywords(query)))
        guard !terms.isEmpty, !items.isEmpty else { return [] }
        let documents = items.map { TextIndex.keywords($0.text) }
        let averageLength = max(1, Double(documents.map(\.count).reduce(0, +)) / Double(documents.count))
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in terms where document.contains(where: { Self.matches($0, term) }) { documentFrequency[term, default: 0] += 1 }
        }
        let total = Double(items.count)
        var scored: [(MemoryItem, Double)] = []
        for (index, document) in documents.enumerated() where !document.isEmpty {
            var matched = 0
            var bm25 = 0.0
            for term in terms {
                let frequency = Double(document.filter { Self.matches($0, term) }.count)
                guard frequency > 0 else { continue }
                matched += 1
                let df = Double(documentFrequency[term] ?? 1)
                let idf = log(1 + (total - df + 0.5) / (df + 0.5))
                let k1 = 1.2, b = 0.75
                bm25 += idf * (frequency * (k1 + 1)) / (frequency + k1 * (1 - b + b * Double(document.count) / averageLength))
            }
            guard matched > 0 else { continue }
            let coverage = Double(matched) / Double(terms.count)
            let ageDays = now.timeIntervalSince(items[index].updatedAt) / 86_400
            let tieBreak = min(0.049, 0.01 * bm25 + 0.005 * exp(-ageDays / 30))
            scored.append((items[index], coverage + tieBreak))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (item: $0.0, score: $0.1) }
    }

    /// Prefix matching tolerates simple inflections ("park" ↔ "parked").
    static func matches(_ word: String, _ term: String) -> Bool {
        if word == term { return true }
        guard min(word.count, term.count) >= 4 else { return false }
        return word.hasPrefix(term) || term.hasPrefix(word)
    }

    /// Items worth giving a model as context for this request. Sensitive items are only
    /// included when the request is clearly about them.
    public func context(for request: String, limit: Int = 6, now: Date = Date()) async -> [MemoryItem] {
        await ensureLoaded()
        let matches = await search(request, limit: limit, now: now)
        // Only clearly relevant items; sensitive ones only when every keyword matches.
        var selected = matches.filter { $0.score >= 0.5 && (!$0.item.isSensitive || $0.score >= 1.0) }.map(\.item)
        // A few standing preferences always help ("call me Rif", "use Spotify").
        let preferences = items.filter { $0.kind == .preference && !$0.isSensitive }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(4)
        for preference in preferences where !selected.contains(where: { $0.id == preference.id }) {
            selected.append(preference)
        }
        return Array(selected.prefix(limit + 2))
    }

    // MARK: Portability

    public func exportJSON() async -> Data {
        await ensureLoaded()
        let encoder = StoreCoding.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(items.sorted { $0.createdAt < $1.createdAt })) ?? Data("[]".utf8)
    }

    @discardableResult
    public func importJSON(_ data: Data, now: Date) async throws -> Int {
        await ensureLoaded()
        let imported = try StoreCoding.decoder().decode([MemoryItem].self, from: data)
        var count = 0
        for var item in imported where !items.contains(where: { $0.id == item.id }) {
            item.source = .imported
            item.updatedAt = now
            items.append(item)
            count += 1
        }
        await persist()
        return count
    }
}
