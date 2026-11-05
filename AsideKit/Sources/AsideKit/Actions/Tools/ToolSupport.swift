import Foundation

/// JSON Schema helpers for tool definitions.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }

    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var schema: JSONValue = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return schema
    }

    static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static let when = string("When, in the user's own words relative to now, e.g. \"tomorrow at 9am\", \"in 30 days\", \"every Monday at 8\". Prefer this over due_iso.")
    static let dueISO = string("Optional ISO 8601 local date-time (e.g. 2026-12-05T09:00) if you computed one. Used only when `when` can't be interpreted.")
}

/// Checks and, when needed, requests access for an integration.
enum Access {
    static func ensure(_ capability: Capability, call: ToolCall,
                       current: () async -> AccessState, request: () async -> AccessState) async -> ToolOutcome? {
        var state = await current()
        if state == .notDetermined { state = await request() }
        switch state {
        case .granted, .limited:
            return nil
        case .unavailable:
            return .failed(ToolFailure(.unavailable, message: "\(capability.displayName) isn't available on this device."))
        case .denied, .notDetermined:
            return .needsPermission(PermissionRequest(
                capability: capability, state: state,
                explanation: "I need access to \(capability.displayName.lowercased()) for that. You can turn it on in Settings.",
                call: call))
        }
    }
}

/// ISO 8601 parsing for model-provided dates, interpreted in the user's time zone when no offset is given.
public enum ISODates {
    public static func parse(_ text: String, timeZone: TimeZone) -> (date: Date, hasTime: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withOffset = ISO8601DateFormatter()
        withOffset.formatOptions = [.withInternetDateTime]
        if let date = withOffset.date(from: trimmed) { return (date, true) }
        withOffset.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withOffset.date(from: trimmed) { return (date, true) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return (date, hasTime) }
        }
        return nil
    }

    public static func string(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }
}

/// Resolves a call's "when"/"due_iso" arguments into a concrete time.
struct ResolvedWhen {
    var date: Date
    var hasTime: Bool
    var recurrence: RecurrenceRule?
    var isInPast: Bool
    var phrase: String?
    var isOffset: Bool

    static func from(_ arguments: JSONValue, context: ExecutionContext, purpose: TemporalPurpose = .schedule) -> ResolvedWhen?? {
        let phrase = arguments["when"]?.nonEmptyString
        if let phrase, let parsed = context.parser.parse(phrase, purpose: purpose) {
            let isOffset = phrase.lowercased().hasPrefix("in ") || phrase.lowercased().contains("from now")
            return .some(ResolvedWhen(date: parsed.start, hasTime: parsed.hasExplicitTime, recurrence: parsed.recurrence,
                                      isInPast: parsed.isInPast, phrase: phrase, isOffset: isOffset))
        }
        if let iso = arguments["due_iso"]?.nonEmptyString ?? arguments["start_iso"]?.nonEmptyString,
           let parsed = ISODates.parse(iso, timeZone: context.temporal.timeZone) {
            return .some(ResolvedWhen(date: parsed.date, hasTime: parsed.hasTime, recurrence: nil,
                                      isInPast: parsed.date < context.now, phrase: phrase, isOffset: false))
        }
        // A phrase was given but couldn't be understood.
        if phrase != nil { return .some(nil) }
        return .none
    }
}

/// Fuzzy title matching for "the reminder about the dentist".
enum TitleMatch {
    static func score(query: String, title: String) -> Double {
        let lowerQuery = query.lowercased()
        let lowerTitle = title.lowercased()
        if lowerTitle == lowerQuery { return 1.0 }
        let queryWords = Set(TextIndex.keywords(query))
        let titleWords = Set(TextIndex.keywords(title))
        guard !queryWords.isEmpty, !titleWords.isEmpty else {
            return lowerTitle.contains(lowerQuery) && !lowerQuery.isEmpty ? 0.7 : 0
        }
        let overlap = Double(queryWords.intersection(titleWords).count)
        var score = overlap / Double(queryWords.count) * 0.85 + overlap / Double(titleWords.count) * 0.15
        if lowerTitle.contains(lowerQuery) { score = max(score, 0.8) }
        return score
    }

    static func best<T>(_ items: [T], query: String, title: (T) -> String, threshold: Double = 0.5) -> [T] {
        let scored = items.map { ($0, score(query: query, title: title($0))) }.filter { $0.1 >= threshold }
        guard let top = scored.map(\.1).max() else { return [] }
        // Keep only items close to the best score.
        return scored.filter { $0.1 >= top - 0.05 }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

extension String {
    /// Shortens text for speech: at most `words` words.
    func spokenPrefix(words: Int) -> String {
        let parts = split(separator: " ")
        guard parts.count > words else { return self }
        return parts.prefix(words).joined(separator: " ") + "…"
    }

    /// "Buy milk" → "buy milk" for mid-sentence read-back (keeps proper nouns and acronyms).
    var lowercasedFirst: String {
        guard let first = first else { return self }
        let secondIsUpper = dropFirst().first?.isUppercase ?? false
        if secondIsUpper { return self }
        return first.lowercased() + dropFirst()
    }

    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Result of looking something up: either the item, or what to tell the user instead.
enum Lookup<T: Sendable>: Sendable {
    case found(T)
    case outcome(ToolOutcome)
}
