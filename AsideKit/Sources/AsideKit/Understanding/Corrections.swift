import Foundation

/// A follow-up that changes what Aside just did: "change it to tomorrow", "make it 20 minutes",
/// "no, I said 3 PM", "call it dentist".
public enum Correction: Sendable, Hashable {
    case reschedule(when: String)
    case retitle(String)
    case changeDuration(text: String)
}

public enum CorrectionParser {
    static let reschedulePrefixes: [[String]] = [
        ["change", "it", "to"], ["change", "that", "to"], ["change", "the", "time", "to"], ["change", "the", "date", "to"],
        ["move", "it", "to"], ["move", "that", "to"], ["move", "it"], ["push", "it", "to"], ["push", "it", "back", "to"], ["push", "it", "back"],
        ["reschedule", "it", "to"], ["reschedule", "it", "for"], ["reschedule", "it"], ["make", "it"], ["make", "that"], ["set", "it", "for"],
        ["set", "it", "to"], ["do", "it"], ["i", "said"], ["i", "meant"], ["no", "i", "said"], ["no", "i", "meant"], ["no"], ["not"],
        ["actually"], ["change", "it"], ["instead"], ["remind", "me"],
    ]

    static let retitlePrefixes: [[String]] = [
        ["rename", "it", "to"], ["rename", "it"], ["call", "it"], ["change", "the", "name", "to"], ["change", "the", "title", "to"],
        ["name", "it"], ["title", "it"],
    ]

    /// Parses a correction. Only meaningful when something recent can be referred to.
    public static func parse(_ utterance: Utterance, referent: Referent) -> Correction? {
        let u = FastPathParser.core(utterance)
        let norms = u.norms
        guard !norms.isEmpty, norms.count <= 12 else { return nil }

        for prefix in retitlePrefixes.sorted(by: { $0.count > $1.count }) where u.hasPrefix(prefix) {
            let title = u.original(prefix.count..<u.count).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : .retitle(title)
        }

        var start = 0
        for prefix in reschedulePrefixes.sorted(by: { $0.count > $1.count }) where u.hasPrefix(prefix) {
            start = prefix.count
            break
        }
        // "no, tomorrow" / "make it tomorrow instead" / "change it to 3pm"
        var end = u.count
        if end > start, norms[end - 1] == "instead" { end -= 1 }
        guard end > start else { return nil }
        let rest = Array(norms[start..<end])
        if rest.first == "to" || rest.first == "for" { start += 1 }
        guard end > start else { return nil }
        let restUtterance = u.slice(start..<end)

        if referent.kind == .timer {
            if let duration = DurationParser.parseWhole(restUtterance.norms), duration.isClockOnly {
                return .changeDuration(text: restUtterance.original(0..<restUtterance.count))
            }
        }
        // Without a correction verb, require the whole remainder to be temporal ("no, tomorrow at 5").
        let probe = TemporalParser(calendar: Calendar(identifier: .gregorian), now: Date(timeIntervalSince1970: 1_800_000_000))
        guard let parsed = probe.parse(restUtterance, purpose: .schedule) else { return nil }
        let coverage = Double(parsed.consumed.count) / Double(max(1, restUtterance.count))
        let hasVerb = start > 0 && !["no", "not", "actually"].contains(norms[0]) || norms.count > 1 && ["i"].contains(norms[min(1, norms.count - 1)])
        guard coverage >= (hasVerb ? 0.6 : 0.9) else { return nil }
        guard [.reminder, .event, .timer].contains(referent.kind) else { return nil }
        return .reschedule(when: restUtterance.original(0..<restUtterance.count))
    }

    /// Turns a correction into a tool call for the referent.
    public static func call(for correction: Correction, referent: Referent, turnID: String) -> ToolCall? {
        switch (correction, referent.kind) {
        case (.reschedule(let when), .reminder):
            return ToolCall(name: "update_reminder", arguments: ["id": .string(referent.id), "when": .string(when)], origin: .correction, turnID: turnID)
        case (.retitle(let title), .reminder):
            return ToolCall(name: "update_reminder", arguments: ["id": .string(referent.id), "title": .string(title)], origin: .correction, turnID: turnID)
        case (.reschedule(let when), .event):
            return ToolCall(name: "update_event", arguments: ["id": .string(referent.id), "when": .string(when)], origin: .correction, turnID: turnID)
        case (.retitle(let title), .event):
            return ToolCall(name: "update_event", arguments: ["id": .string(referent.id), "title": .string(title)], origin: .correction, turnID: turnID)
        case (.changeDuration(let text), .timer):
            return ToolCall(name: "update_timer", arguments: ["id": .string(referent.id), "duration": .string(text)], origin: .correction, turnID: turnID)
        default:
            return nil
        }
    }
}
