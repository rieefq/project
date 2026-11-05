import Foundation

/// Renders dates, times, durations and lists the way a person would say them.
///
/// Spoken output should never sound like a log line: "tomorrow at 9", not
/// "2026-11-06T09:00:00". Relative phrasing is used close to now, absolute phrasing
/// further out, and the weekday is added when it removes ambiguity.
public struct SpokenFormatter: Sendable {
    public var context: TemporalContext
    public var now: Date

    public init(context: TemporalContext, now: Date) {
        self.context = context
        self.now = now
    }

    private var calendar: Calendar { context.calendar }
    private var isEnglish: Bool { context.locale.language.languageCode?.identifier ?? "en" == "en" }

    private func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.timeZone = context.timeZone
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    // MARK: Times

    /// "9 AM", "9:30 AM", "noon", "midnight" (or "17:30" on 24-hour locales).
    public func time(_ date: Date) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        if isEnglish && minute == 0 {
            if hour == 12 { return "noon" }
            if hour == 0 { return "midnight" }
        }
        if context.uses12HourClock {
            return formatter(minute == 0 ? "j" : "j:mm").string(from: date)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        return formatter("HH:mm").string(from: date)
    }

    // MARK: Days

    /// "today", "tomorrow", "yesterday", "Friday", "next Friday", "December 5th", "January 3rd, 2028".
    public func day(_ date: Date) -> String {
        let startToday = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startToday, to: startDate).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6: return formatter("EEEE").string(from: date)
        default: break
        }
        return monthDay(date, includeYear: !calendar.isDate(date, equalTo: now, toGranularity: .year) && abs(days) > 60)
    }

    /// "December 5th" (English ordinals), localized month names elsewhere.
    public func monthDay(_ date: Date, includeYear: Bool = false) -> String {
        let dayNumber = calendar.component(.day, from: date)
        if isEnglish {
            let month = formatter("MMMM").string(from: date)
            var text = "\(month) \(dayNumber)\(NumberWords.ordinalSuffix(dayNumber))"
            if includeYear { text += ", \(calendar.component(.year, from: date))" }
            return text
        }
        return formatter(includeYear ? "MMMMdyyyy" : "MMMMd").string(from: date)
    }

    /// "tomorrow at 9 AM", "on Friday at noon", "on December 5th", "at 5 PM", "Saturday, December 5th".
    public func when(_ date: Date, includeTime: Bool, includeWeekday: Bool = false) -> String {
        let dayText = day(date)
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        var text: String
        switch dayText {
        case "today":
            text = includeTime ? "" : "today"
        case "tomorrow", "yesterday":
            text = dayText
        default:
            if includeWeekday, !dayText.contains(where: \.isNumber) {
                text = "on \(dayText), \(monthDay(date))"
            } else if includeWeekday {
                text = "on \(formatter("EEEE").string(from: date)), \(dayText)"
            } else {
                text = "on \(dayText)"
            }
        }
        if includeTime {
            let timeText = time(date)
            let joiner = (timeText == "noon" || timeText == "midnight") ? "at" : "at"
            text = text.isEmpty ? "\(joiner) \(timeText)" : "\(text) \(joiner) \(timeText)"
            if sameDay && text.hasPrefix("at ") {
                // "at 5 PM" reads naturally on its own for today.
                return text
            }
        }
        return text
    }

    /// The same phrase without a leading preposition, for "moved it to …": "Saturday at 9 AM", "5 PM".
    public func destination(_ date: Date, includeTime: Bool) -> String {
        var text = when(date, includeTime: includeTime)
        for prefix in ["on ", "at "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
    }

    // MARK: Durations

    /// "10 minutes", "an hour and a half", "2 hours and 5 minutes", "30 seconds".
    public func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return total == 1 ? "1 second" : "\(total) seconds" }
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours == 0 {
            if secs >= 30 && minutes < 5 && secs != 0 {
                return minutes == 1 ? "a minute and a half" : "\(minutes) and a half minutes"
            }
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        if minutes == 30 && secs == 0 {
            return hours == 1 ? "an hour and a half" : "\(hours) and a half hours"
        }
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        if minutes == 0 { return hourText }
        return "\(hourText) and \(minutes == 1 ? "1 minute" : "\(minutes) minutes")"
    }

    /// Long spans: "3 days", "2 weeks", "about 4 months".
    public func span(from start: Date, to end: Date) -> String {
        let components = calendar.dateComponents([.day, .hour, .minute], from: start, to: end)
        let days = components.day ?? 0
        if days >= 60 { return "about \(days / 30) months" }
        if days >= 14 && days % 7 == 0 { return "\(days / 7) weeks" }
        if days >= 1 { return days == 1 ? "1 day" : "\(days) days" }
        return duration(end.timeIntervalSince(start))
    }

    // MARK: Lists & numbers

    /// "a", "a and b", "a, b, and c".
    public func list(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items[items.count - 1]
        }
    }

    /// Spoken count: "one", "two", ... "twelve", then digits.
    public func count(_ value: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return value >= 0 && value < words.count ? words[value] : String(value)
    }

    /// Rounds a number for speech: 3.14159 → "3.1", 12.0 → "12", 1234567 → "1,234,567".
    public func number(_ value: Double, maxFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = context.locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) >= 100 ? 0 : maxFractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Converts first-person phrasing to second person for read-backs:
/// "change my toothbrush" → "change your toothbrush".
public enum PerspectiveShifter {
    static let map: [String: String] = [
        "i": "you", "me": "you", "my": "your", "mine": "yours", "myself": "yourself",
        "i'm": "you're", "i've": "you've", "i'll": "you'll", "i'd": "you'd", "am": "are",
        "we": "you", "us": "you", "our": "your", "ours": "yours", "ourselves": "yourselves",
    ]

    public static func secondPerson(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        for (index, word) in words.enumerated() {
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            let lower = trimmed.lowercased()
            guard var replacement = map[lower] else { output.append(word); continue }
            // "am" only changes after "I" ("I am late" → "you are late").
            if lower == "am" {
                let previous = index > 0 ? words[index - 1].lowercased().trimmingCharacters(in: .punctuationCharacters) : ""
                if previous != "i" { output.append(word); continue }
            }
            // "us" after "let" stays ("let us know" is rare in commands; keep it simple).
            if trimmed.first?.isUppercase == true && lower != "i" {
                replacement = replacement.prefix(1).uppercased() + replacement.dropFirst()
            }
            output.append(word.replacingOccurrences(of: trimmed, with: replacement))
        }
        return output.joined(separator: " ")
    }
}

/// Makes model text safe and pleasant to speak: strips markdown, URLs and symbols.
public enum SpeechText {
    public static func sanitize(_ text: String) -> String {
        var result = text
        // Markdown links [label](url) → label
        result = replace(result, pattern: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1")
        // Bare URLs → "a link"
        result = replace(result, pattern: #"https?://\S+"#, with: "a link")
        // Code ticks, emphasis, headings
        result = result.replacingOccurrences(of: "`", with: "")
        result = replace(result, pattern: #"\*\*([^*]+)\*\*"#, with: "$1")
        result = replace(result, pattern: #"__([^_]+)__"#, with: "$1")
        result = replace(result, pattern: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "")
        // List bullets at line start
        result = replace(result, pattern: #"(?m)^\s*([-*•]|\d+[.)])\s+"#, with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        // Common symbols
        result = result.replacingOccurrences(of: " & ", with: " and ")
        result = result.replacingOccurrences(of: "e.g.", with: "for example")
        result = result.replacingOccurrences(of: "i.e.", with: "that is")
        result = result.replacingOccurrences(of: "→", with: "to")
        // Remove emoji and pictographs
        result = String(result.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C))
        }.map(Character.init))
        // Newlines become sentence breaks; collapse whitespace.
        result = replace(result, pattern: #"\s*\n+\s*"#, with: ". ")
        result = replace(result, pattern: #"\.\s*\.\s"#, with: ". ")
        result = replace(result, pattern: #"[ \t]{2,}"#, with: " ")
        result = result.replacingOccurrences(of: ":.", with: ":")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Splits a stream of model text into speakable chunks as early as possible.
///
/// The first chunk may break at a clause boundary so speech can start while the
/// model is still writing; later chunks break at sentence ends.
public struct SentenceChunker: Sendable {
    private var buffer = ""
    private var emittedAny = false
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "jr", "sr", "no", "approx", "inc", "ltd", "mt", "ft", "u.s", "a.m", "p.m"]

    public init() {}

    public mutating func append(_ delta: String) -> [String] {
        buffer += delta
        var chunks: [String] = []
        while let cut = nextBoundary() {
            let chunk = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !chunk.isEmpty { chunks.append(chunk); emittedAny = true }
        }
        return chunks
    }

    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    private func nextBoundary() -> String.Index? {
        let characters = Array(buffer)
        guard characters.count > 1 else { return nil }
        for index in 0..<(characters.count - 1) {
            let character = characters[index]
            let next = characters[index + 1]
            if character == "\n" {
                return buffer.index(buffer.startIndex, offsetBy: index + 1)
            }
            if ".!?".contains(character), next.isWhitespace {
                if character == "." && isAbbreviation(endingAt: index, in: characters) { continue }
                return buffer.index(buffer.startIndex, offsetBy: index + 1)
            }
            // Early clause break for the first chunk to cut time-to-first-audio.
            if !emittedAny, index > 48, ",;:".contains(character), next.isWhitespace {
                return buffer.index(buffer.startIndex, offsetBy: index + 1)
            }
        }
        return nil
    }

    private func isAbbreviation(endingAt index: Int, in characters: [Character]) -> Bool {
        var start = index
        while start > 0, characters[start - 1].isLetter || characters[start - 1] == "." { start -= 1 }
        let word = String(characters[start..<index]).lowercased()
        if word.count == 1 { return true } // initials like "J."
        return Self.abbreviations.contains(word)
    }
}
