import Foundation

/// What a temporal phrase is being used for. Scheduling wants a future instant;
/// questions ("what's on tomorrow?") want an interval.
public enum TemporalPurpose: Sendable {
    case schedule
    case query
}

/// Personal defaults for vague times. Users can adjust these ("my mornings start at 7").
public struct TemporalDefaults: Sendable, Hashable, Codable {
    public var morningHour: Int = 9
    public var afternoonHour: Int = 14
    public var eveningHour: Int = 18
    public var nightHour: Int = 20
    public var endOfDayHour: Int = 17
    public var dateOnlyHour: Int = 9
    public var weekendHour: Int = 10
    public var awakeStartHour: Int = 7
    public var awakeEndHour: Int = 22

    public init() {}
}

/// A recurrence pattern ("every Monday", "every 2 weeks").
public struct RecurrenceRule: Sendable, Hashable, Codable {
    public enum Frequency: String, Sendable, Codable {
        case daily, weekly, monthly, yearly
    }

    public var frequency: Frequency
    public var interval: Int
    /// Calendar weekday numbers: 1 = Sunday ... 7 = Saturday.
    public var weekdays: [Int]

    public init(frequency: Frequency, interval: Int = 1, weekdays: [Int] = []) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
    }
}

/// The resolved meaning of a temporal phrase.
public struct TemporalResult: Sendable, Hashable {
    /// The instant (schedule) or interval start (query).
    public var start: Date
    /// Interval end for queries.
    public var end: Date?
    /// The user said a time of day ("at 5", "noon", "in 20 minutes").
    public var hasExplicitTime: Bool
    /// The user said a day or an offset.
    public var hasExplicitDay: Bool
    public var recurrence: RecurrenceRule?
    /// Token indices that belong to the temporal phrase (for stripping from titles).
    public var consumed: Set<Int>
    /// The resolved instant is already in the past (e.g. "today at 9" said at 10).
    public var isInPast: Bool
    /// Some part was guessed (am/pm inference, "later").
    public var isApproximate: Bool

    public var interval: DateInterval? {
        guard let end, end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

/// Deterministic parser for English temporal expressions.
///
/// Models are good at language and poor at date arithmetic, so Aside always grounds
/// "when" phrases with this parser — whether the phrase came from the fast path, the
/// on-device model or the cloud model.
public struct TemporalParser: Sendable {
    public var calendar: Calendar
    public var now: Date
    public var defaults: TemporalDefaults
    public var monthFirstNumericDates: Bool

    public init(calendar: Calendar, now: Date, defaults: TemporalDefaults = TemporalDefaults(), locale: Locale? = nil) {
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
        let loc = locale ?? calendar.locale ?? Locale(identifier: "en_US")
        let template = DateFormatter.dateFormat(fromTemplate: "Md", options: 0, locale: loc) ?? "M/d"
        let monthIndex = template.firstIndex(of: "M")
        let dayIndex = template.firstIndex(of: "d")
        if let monthIndex, let dayIndex { monthFirstNumericDates = monthIndex < dayIndex } else { monthFirstNumericDates = true }
    }

    // MARK: Public API

    public func parse(_ text: String, purpose: TemporalPurpose) -> TemporalResult? {
        parse(Utterance(text), purpose: purpose)
    }

    public func parse(_ utterance: Utterance, purpose: TemporalPurpose, range: Range<Int>? = nil) -> TemporalResult? {
        let norms = utterance.norms
        let scanRange = (range ?? 0..<norms.count).clamped(to: 0..<norms.count)
        let matches = scan(norms, range: scanRange)
        guard !matches.isEmpty else { return nil }
        return combine(matches, purpose: purpose)
    }

    // MARK: Parts

    enum WeekdayModifier: Hashable { case plain, this, next }

    enum DayRef: Hashable {
        case relative(Int)
        case weekday(Int, WeekdayModifier)
        case date(month: Int, day: Int, year: Int?)
        case dayOfMonth(Int)
        case week(offset: Int)
        case weekend(offset: Int)
        case month(offset: Int)
        case endOfWeek
        case endOfMonth
    }

    enum Period: Hashable { case morning, afternoon, evening, night, endOfDay, firstThing }

    enum Meridiem: Hashable { case am, pm }

    struct ClockTime: Hashable {
        var hour: Int
        var minute: Int
        var meridiem: Meridiem?
        var isMidnight = false
        var is24Hour = false
    }

    enum Part: Hashable {
        case offset(SpokenDuration, approximate: Bool)
        case day(DayRef)
        case time(ClockTime)
        case period(Period, impliesToday: Bool)
        case recurrence(RecurrenceRule, period: Period?)
    }

    struct Match: Hashable {
        var range: Range<Int>
        var part: Part
    }

    // MARK: Vocabulary

    static let weekdayNames: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
    ]

    static let weekdayPlurals: [String: Int] = [
        "sundays": 1, "mondays": 2, "tuesdays": 3, "wednesdays": 4, "thursdays": 5, "fridays": 6, "saturdays": 7,
    ]

    static let monthNames: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7,
        "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9,
        "oct": 10, "nov": 11, "dec": 12,
    ]

    static func weekday(_ word: String) -> Int? {
        if let value = weekdayNames[word] { return value }
        // "friday's" (possessive from the recognizer)
        if word.hasSuffix("'s"), let value = weekdayNames[String(word.dropLast(2))] { return value }
        return nil
    }

    // MARK: Scanning

    func scan(_ n: [String], range: Range<Int>) -> [Match] {
        var matches: [Match] = []
        var index = range.lowerBound
        let window = Array(n[..<range.upperBound])
        while index < range.upperBound {
            if let match = matchAt(window, index) {
                matches.append(match)
                index = max(match.range.upperBound, index + 1)
            } else {
                index += 1
            }
        }
        return matches
    }

    func matchAt(_ n: [String], _ i: Int) -> Match? {
        matchRecurrence(n, i)
            ?? matchOffset(n, i)
            ?? matchRelativeDay(n, i)
            ?? matchWeekday(n, i)
            ?? matchDate(n, i)
            ?? matchTime(n, i)
            ?? matchPeriod(n, i)
    }

    private func word(_ n: [String], _ i: Int) -> String? { i >= 0 && i < n.count ? n[i] : nil }

    // MARK: Recurrence

    func matchRecurrence(_ n: [String], _ i: Int) -> Match? {
        guard let first = word(n, i) else { return nil }
        switch first {
        case "daily": return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .daily), period: nil))
        case "nightly": return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .daily), period: .night))
        case "weekly": return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .weekly), period: nil))
        case "monthly": return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .monthly), period: nil))
        case "yearly", "annually": return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .yearly), period: nil))
        case "weekdays":
            return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]), period: nil))
        default: break
        }
        if first == "on", let next = word(n, i + 1) {
            if let weekday = Self.weekdayPlurals[next] {
                return Match(range: i..<(i + 2), part: .recurrence(RecurrenceRule(frequency: .weekly, weekdays: [weekday]), period: nil))
            }
            if next == "weekdays" {
                return Match(range: i..<(i + 2), part: .recurrence(RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]), period: nil))
            }
            if next == "weekends" {
                return Match(range: i..<(i + 2), part: .recurrence(RecurrenceRule(frequency: .weekly, weekdays: [1, 7]), period: nil))
            }
        }
        if let weekday = Self.weekdayPlurals[first] {
            return Match(range: i..<(i + 1), part: .recurrence(RecurrenceRule(frequency: .weekly, weekdays: [weekday]), period: nil))
        }
        guard first == "every" || first == "each" else { return nil }
        var j = i + 1
        var interval = 1
        if word(n, j) == "other" { interval = 2; j += 1 }
        if let count = word(n, j).flatMap({ Int($0) }), count > 0, count < 400 { interval = count; j += 1 }
        guard let unit = word(n, j) else { return nil }
        switch unit {
        case "day", "days":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .daily, interval: interval), period: nil))
        case "morning", "mornings":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .daily, interval: interval), period: .morning))
        case "afternoon", "afternoons":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .daily, interval: interval), period: .afternoon))
        case "evening", "evenings":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .daily, interval: interval), period: .evening))
        case "night", "nights":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .daily, interval: interval), period: .night))
        case "weekday", "weekdays":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .weekly, interval: interval, weekdays: [2, 3, 4, 5, 6]), period: nil))
        case "weekend", "weekends":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .weekly, interval: interval, weekdays: [1, 7]), period: nil))
        case "week", "weeks":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .weekly, interval: interval), period: nil))
        case "month", "months":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .monthly, interval: interval), period: nil))
        case "year", "years":
            return Match(range: i..<(j + 1), part: .recurrence(RecurrenceRule(frequency: .yearly, interval: interval), period: nil))
        default:
            break
        }
        // "every monday", "every monday and thursday", "every tuesday morning"
        guard let firstWeekday = Self.weekday(unit) ?? Self.weekdayPlurals[unit] else { return nil }
        var weekdays = [firstWeekday]
        var end = j + 1
        while let connector = word(n, end), connector == "and" || connector == "or",
              let next = word(n, end + 1), let weekday = Self.weekday(next) ?? Self.weekdayPlurals[next] {
            weekdays.append(weekday)
            end += 2
        }
        var period: Period?
        if let periodWord = word(n, end), let found = Self.periodWord(periodWord) {
            period = found
            end += 1
        }
        return Match(range: i..<end, part: .recurrence(RecurrenceRule(frequency: .weekly, interval: interval, weekdays: weekdays), period: period))
    }

    static func periodWord(_ word: String) -> Period? {
        switch word {
        case "morning", "mornings": return .morning
        case "afternoon", "afternoons": return .afternoon
        case "evening", "evenings": return .evening
        case "night", "nights": return .night
        default: return nil
        }
    }

    // MARK: Offsets

    func matchOffset(_ n: [String], _ i: Int) -> Match? {
        guard let first = word(n, i) else { return nil }
        if first == "in" || first == "within" {
            var j = i + 1
            var approximate = false
            if let qualifier = word(n, j), ["about", "around", "roughly", "like", "approximately", "just"].contains(qualifier) {
                approximate = qualifier != "just"
                j += 1
            }
            if let (duration, end) = DurationParser.parse(n, at: j) {
                return Match(range: i..<end, part: .offset(duration, approximate: approximate))
            }
            return nil
        }
        if first == "later" {
            var end = i + 1
            if word(n, end) == "today" || word(n, end) == "on" && word(n, end + 1) == "today" {
                end += word(n, end) == "on" ? 2 : 1
            }
            return Match(range: i..<end, part: .offset(SpokenDuration(seconds: 3 * 3_600), approximate: true))
        }
        if let (duration, end) = DurationParser.parse(n, at: i) {
            if word(n, end) == "from", let anchor = word(n, end + 1), anchor == "now" || anchor == "today" {
                return Match(range: i..<(end + 2), part: .offset(duration, approximate: false))
            }
            if word(n, end) == "later" || word(n, end) == "after" && word(n, end + 1) == "now" {
                return Match(range: i..<(end + 1), part: .offset(duration, approximate: false))
            }
        }
        return nil
    }

    // MARK: Relative days

    func matchRelativeDay(_ n: [String], _ i: Int) -> Match? {
        guard var first = word(n, i) else { return nil }
        var start = i
        if first == "the", word(n, i + 1) == "day", word(n, i + 2) == "after", word(n, i + 3) == "tomorrow" {
            return Match(range: i..<(i + 4), part: .day(.relative(2)))
        }
        if first == "day", word(n, i + 1) == "after", word(n, i + 2) == "tomorrow" {
            return Match(range: i..<(i + 3), part: .day(.relative(2)))
        }
        if first == "by" || first == "for" || first == "on" || first == "until", let next = word(n, i + 1),
           ["today", "tonight", "tomorrow", "tomorrow's", "tmrw"].contains(next) {
            start = i
            first = next
            return relativeDay(first, range: start..<(i + 2))
        }
        if let match = relativeDay(first, range: i..<(i + 1)) { return match }

        // this/next week, weekend, month; end of week/month; "this morning".
        var j = i
        var offset = 0
        var sawModifier = false
        if (first == "on" || first == "over" || first == "for" || first == "during") && word(n, i + 1) == "the" && word(n, i + 2) == "weekend" {
            return Match(range: i..<(i + 3), part: .day(.weekend(offset: 0)))
        }
        if first == "this" || first == "the" { j += 1; sawModifier = true }
        else if first == "next" { j += 1; offset = 1; sawModifier = true }
        else if first == "coming" || first == "upcoming" { j += 1; sawModifier = true }
        if word(n, j) == "coming" && first == "this" { j += 1 }
        guard let unit = word(n, j) else { return nil }
        switch unit {
        case "week" where sawModifier && first != "the":
            return Match(range: i..<(j + 1), part: .day(.week(offset: offset)))
        case "weekend" where sawModifier:
            return Match(range: i..<(j + 1), part: .day(.weekend(offset: offset)))
        case "month" where sawModifier && first != "the":
            return Match(range: i..<(j + 1), part: .day(.month(offset: offset)))
        case "morning" where first == "this":
            return Match(range: i..<(j + 1), part: .period(.morning, impliesToday: true))
        case "afternoon" where first == "this":
            return Match(range: i..<(j + 1), part: .period(.afternoon, impliesToday: true))
        case "evening" where first == "this":
            return Match(range: i..<(j + 1), part: .period(.evening, impliesToday: true))
        default:
            break
        }
        // "end of (the) week/month", "by the end of the week"
        var k = i
        if word(n, k) == "by" { k += 1 }
        if word(n, k) == "the" { k += 1 }
        if word(n, k) == "end", word(n, k + 1) == "of" {
            var m = k + 2
            if word(n, m) == "the" || word(n, m) == "this" { m += 1 }
            if word(n, m) == "week" { return Match(range: i..<(m + 1), part: .day(.endOfWeek)) }
            if word(n, m) == "month" { return Match(range: i..<(m + 1), part: .day(.endOfMonth)) }
        }
        return nil
    }

    private func relativeDay(_ word: String, range: Range<Int>) -> Match? {
        switch word {
        case "today": return Match(range: range, part: .day(.relative(0)))
        case "tonight": return Match(range: range, part: .period(.night, impliesToday: true))
        case "tomorrow", "tomorrow's", "tmrw": return Match(range: range, part: .day(.relative(1)))
        case "yesterday": return Match(range: range, part: .day(.relative(-1)))
        default: return nil
        }
    }

    // MARK: Weekdays

    func matchWeekday(_ n: [String], _ i: Int) -> Match? {
        guard let first = word(n, i) else { return nil }
        var j = i
        var modifier = WeekdayModifier.plain
        if first == "on" || first == "by" || first == "until" || first == "for" { j += 1 }
        if word(n, j) == "this" { modifier = .this; j += 1; if word(n, j) == "coming" { j += 1 } }
        else if word(n, j) == "next" { modifier = .next; j += 1 }
        else if word(n, j) == "coming" || word(n, j) == "upcoming" { modifier = .this; j += 1 }
        guard let candidate = word(n, j), let weekday = Self.weekday(candidate) else { return nil }
        // "on friday" / "friday" / "next friday"
        return Match(range: i..<(j + 1), part: .day(.weekday(weekday, modifier)))
    }

    // MARK: Dates

    func matchDate(_ n: [String], _ i: Int) -> Match? {
        guard let first = word(n, i) else { return nil }
        var j = i
        if first == "on" || first == "by" || first == "until" || first == "for" { j += 1 }
        guard let head = word(n, j) else { return nil }

        // ISO 2026-12-05
        if head.count == 10, head.split(separator: "-").count == 3 {
            let parts = head.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) {
                return Match(range: i..<(j + 1), part: .day(.date(month: parts[1], day: parts[2], year: parts[0])))
            }
        }
        // Numeric 6/3 or 6/3/2027
        if head.contains("/") {
            let parts = head.split(separator: "/").compactMap { Int($0) }
            if parts.count >= 2 {
                let month = monthFirstNumericDates ? parts[0] : parts[1]
                let day = monthFirstNumericDates ? parts[1] : parts[0]
                var year: Int? = parts.count >= 3 ? parts[2] : nil
                if let y = year, y < 100 { year = 2000 + y }
                if (1...12).contains(month), (1...31).contains(day) {
                    return Match(range: i..<(j + 1), part: .day(.date(month: month, day: day, year: year)))
                }
            }
        }
        // "june 3rd", "june the 3rd", "june 3", "june 3rd 2027"
        if let month = Self.monthNames[head] {
            var k = j + 1
            if word(n, k) == "the" { k += 1 }
            if let dayWord = word(n, k), let day = dayNumber(dayWord, allowCardinal: true) {
                var end = k + 1
                var year: Int?
                if let yearWord = word(n, end), let value = Int(yearWord), value >= 1900, value < 2200 {
                    year = value
                    end += 1
                }
                return Match(range: i..<end, part: .day(.date(month: month, day: day, year: year)))
            }
            return nil
        }
        // "the 3rd (of june)", "3rd of june", "the second of june"
        var k = j
        if word(n, k) == "the" { k += 1 }
        if let dayWord = word(n, k), let day = dayNumber(dayWord, allowCardinal: false) {
            if word(n, k + 1) == "of", let monthWord = word(n, k + 2), let month = Self.monthNames[monthWord] {
                var end = k + 3
                var year: Int?
                if let yearWord = word(n, end), let value = Int(yearWord), value >= 1900, value < 2200 {
                    year = value
                    end += 1
                }
                return Match(range: i..<end, part: .day(.date(month: month, day: day, year: year)))
            }
            // A bare ordinal is only a day of month when introduced ("on the 3rd", "the 21st").
            if (word(n, k - 1) == "the" && (first == "on" || first == "the" || first == "by")) && dayWord != "second" {
                return Match(range: i..<(k + 1), part: .day(.dayOfMonth(day)))
            }
        }
        return nil
    }

    private func dayNumber(_ word: String, allowCardinal: Bool) -> Int? {
        if word == "second" { return 2 }
        if let value = NumberWords.numericOrdinal(word), (1...31).contains(value) { return value }
        if allowCardinal, let value = Int(word), (1...31).contains(value) { return value }
        return nil
    }

    // MARK: Times

    func matchTime(_ n: [String], _ i: Int) -> Match? {
        guard let first = word(n, i) else { return nil }
        var j = i
        var hasConnector = false
        if ["at", "around", "by", "@", "until", "til", "till"].contains(first) {
            j += 1
            hasConnector = true
            if word(n, j) == "around" || word(n, j) == "about" { j += 1 }
        }
        if word(n, j) == "a", word(n, j + 1) == "quarter" { j += 1 }
        guard let head = word(n, j) else { return nil }

        // noon / midnight
        if head == "noon" || head == "midday" || head == "lunchtime" {
            return Match(range: i..<(j + 1), part: .time(ClockTime(hour: 12, minute: 0, meridiem: .pm)))
        }
        if head == "12", word(n, j + 1) == "noon" {
            return Match(range: i..<(j + 2), part: .time(ClockTime(hour: 12, minute: 0, meridiem: .pm)))
        }
        if head == "midnight" {
            return Match(range: i..<(j + 1), part: .time(ClockTime(hour: 0, minute: 0, meridiem: nil, isMidnight: true)))
        }

        // half past 5, quarter past 5, quarter to 6, 20 past 5, 10 to 6
        if head == "half" || head == "quarter" || Int(head) != nil && ["past", "after", "to", "til", "before"].contains(word(n, j + 1) ?? "") {
            var minutes: Int?
            var k = j + 1
            if head == "half" { minutes = 30 }
            else if head == "quarter" { minutes = 15 }
            else if let value = Int(head), value > 0, value < 60 { minutes = value }
            if word(n, k) == "minutes" || word(n, k) == "minute" { k += 1 }
            if let minutes, let relation = word(n, k), let hourWord = word(n, k + 1), let hour = Int(hourWord), (1...12).contains(hour) {
                var end = k + 2
                var meridiem: Meridiem?
                if let m = meridiemWord(word(n, end)) { meridiem = m; end += 1 }
                if relation == "past" || relation == "after" {
                    return Match(range: i..<end, part: .time(ClockTime(hour: hour, minute: minutes, meridiem: meridiem)))
                }
                if relation == "to" || relation == "til" || relation == "before" {
                    let adjustedHour = hour == 1 ? 12 : hour - 1
                    return Match(range: i..<end, part: .time(ClockTime(hour: adjustedHour, minute: 60 - minutes, meridiem: meridiem)))
                }
            }
        }

        // H:MM (am|pm)?
        if head.contains(":") {
            let parts = head.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
            var end = j + 1
            var meridiem: Meridiem?
            if let m = meridiemWord(word(n, end)) { meridiem = m; end += 1 }
            let hour = parts[0]
            let is24Hour = meridiem == nil && (head.hasPrefix("0") || hour > 12)
            return Match(range: i..<end, part: .time(ClockTime(hour: hour, minute: parts[1],
                                                               meridiem: hour > 12 ? nil : meridiem,
                                                               is24Hour: is24Hour || hour > 12)))
        }

        // H (am|pm|oclock) or "at H"
        guard let hour = Int(head), (0...23).contains(hour), !head.contains(".") else { return nil }
        var end = j + 1
        var minute = 0
        var meridiem: Meridiem?
        var explicit = hasConnector
        // "5 30 pm" / "5 oh 5"
        if let next = word(n, end), let minuteValue = Int(next), next.count == 2, (0...59).contains(minuteValue), hour <= 12 {
            if meridiemWord(word(n, end + 1)) != nil || hasConnector {
                minute = minuteValue
                end += 1
            }
        } else if word(n, end) == "oh", let next = word(n, end + 1), let minuteValue = Int(next), (0...9).contains(minuteValue) {
            minute = minuteValue
            end += 2
        }
        if word(n, end) == "oclock" { end += 1; explicit = true }
        if let m = meridiemWord(word(n, end)) {
            meridiem = m
            end += 1
            explicit = true
        }
        guard explicit else { return nil }
        if hour > 12 || hour == 0 {
            return Match(range: i..<end, part: .time(ClockTime(hour: hour, minute: minute, meridiem: nil, is24Hour: true)))
        }
        return Match(range: i..<end, part: .time(ClockTime(hour: hour, minute: minute, meridiem: meridiem)))
    }

    private func meridiemWord(_ word: String?) -> Meridiem? {
        switch word {
        case "am", "a.m": return .am
        case "pm", "p.m": return .pm
        default: return nil
        }
    }

    // MARK: Periods

    func matchPeriod(_ n: [String], _ i: Int) -> Match? {
        guard let first = word(n, i) else { return nil }
        // "first thing (in the morning)"
        if first == "1st", word(n, i + 1) == "thing" {
            var end = i + 2
            if word(n, end) == "in", word(n, end + 1) == "the", word(n, end + 2) == "morning" { end += 3 }
            return Match(range: i..<end, part: .period(.firstThing, impliesToday: false))
        }
        var j = i
        if first == "in" && word(n, i + 1) == "the" { j += 2 }
        else if first == "at" || first == "during" || first == "by" || first == "this" { j += 1 }
        if word(n, j) == "the" && first == "during" { j += 1 }
        guard let head = word(n, j) else { return nil }
        if let period = Self.periodWord(head) {
            // "at night" is fine; "night" alone only after a day word is handled by combination.
            if first == "at" && period != .night { return nil }
            return Match(range: i..<(j + 1), part: .period(period, impliesToday: first == "this"))
        }
        if head == "end", word(n, j + 1) == "of", word(n, j + 2) == "day" || (word(n, j + 2) == "the" && word(n, j + 3) == "day") {
            let end = word(n, j + 2) == "the" ? j + 4 : j + 3
            return Match(range: i..<end, part: .period(.endOfDay, impliesToday: false))
        }
        if head == "eod" || head == "cob" {
            return Match(range: i..<(j + 1), part: .period(.endOfDay, impliesToday: false))
        }
        if head == "close", word(n, j + 1) == "of", word(n, j + 2) == "business" {
            return Match(range: i..<(j + 3), part: .period(.endOfDay, impliesToday: false))
        }
        return nil
    }

    // MARK: Combination

    func combine(_ matches: [Match], purpose: TemporalPurpose) -> TemporalResult? {
        var offset: (SpokenDuration, Bool)?
        var day: DayRef?
        var time: ClockTime?
        var period: Period?
        var periodImpliesToday = false
        var recurrence: (RecurrenceRule, Period?)?
        var consumed = Set<Int>()

        for match in matches {
            var used = true
            switch match.part {
            case .offset(let duration, let approximate):
                if offset == nil { offset = (duration, approximate) } else { used = false }
            case .day(let ref):
                if day == nil { day = ref } else { used = false }
            case .time(let clock):
                if time == nil { time = clock } else { used = false }
            case .period(let value, let impliesToday):
                if period == nil { period = value; periodImpliesToday = impliesToday } else { used = false }
            case .recurrence(let rule, let recurrencePeriod):
                if recurrence == nil { recurrence = (rule, recurrencePeriod) } else { used = false }
            }
            if used { consumed.formUnion(match.range) }
        }

        if let (_, recurrencePeriod) = recurrence, period == nil { period = recurrencePeriod }

        switch purpose {
        case .schedule:
            return resolveSchedule(offset: offset, day: day, time: time, period: period,
                                   periodImpliesToday: periodImpliesToday, recurrence: recurrence?.0, consumed: consumed)
        case .query:
            return resolveQuery(offset: offset, day: day, time: time, period: period,
                                periodImpliesToday: periodImpliesToday, consumed: consumed)
        }
    }

    // MARK: Resolution helpers

    var startOfToday: Date { calendar.startOfDay(for: now) }

    func addDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }

    func at(_ day: Date, hour: Int, minute: Int) -> Date {
        let base = calendar.startOfDay(for: day)
        if hour >= 24 {
            return calendar.date(bySettingHour: 0, minute: minute, second: 0, of: addDays(1, to: base)) ?? base
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
    }

    func defaultHour(for period: Period) -> (Int, Int) {
        switch period {
        case .morning: return (defaults.morningHour, 0)
        case .afternoon: return (defaults.afternoonHour, 0)
        case .evening: return (defaults.eveningHour, 0)
        case .night: return (defaults.nightHour, 0)
        case .endOfDay: return (defaults.endOfDayHour, 0)
        case .firstThing: return (max(defaults.awakeStartHour, defaults.morningHour - 1), 0)
        }
    }

    func periodInterval(_ period: Period, on day: Date) -> (Date, Date) {
        let start = calendar.startOfDay(for: day)
        func h(_ value: Int) -> Date { at(start, hour: value, minute: 0) }
        switch period {
        case .morning, .firstThing: return (h(5), h(12))
        case .afternoon: return (h(12), h(17))
        case .evening: return (h(17), h(21))
        case .night: return (h(18), addDays(1, to: start))
        case .endOfDay: return (h(15), h(18))
        }
    }

    /// Calendar weekday of `date` (1 = Sunday).
    func weekday(of date: Date) -> Int { calendar.component(.weekday, from: date) }

    func upcoming(weekday target: Int, modifier: WeekdayModifier, allowToday: Bool) -> Date {
        let today = weekday(of: now)
        var delta = (target - today + 7) % 7
        if delta == 0 && !allowToday { delta = 7 }
        var result = addDays(delta, to: startOfToday)
        if modifier == .next {
            // "next friday" said on a Wednesday means the Friday of next week.
            if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now), thisWeek.contains(result) {
                result = addDays(7, to: result)
            }
        }
        return result
    }

    /// - Parameter laterToday: nil when no time of day was given; otherwise whether that time is still ahead today.
    func resolveDay(_ ref: DayRef, laterToday: Bool?) -> Date {
        switch ref {
        case .relative(let days):
            return addDays(days, to: startOfToday)
        case .weekday(let target, let modifier):
            let today = weekday(of: now)
            if target == today {
                // "this friday" on a Friday is today; plain "friday at 5" is today only if 5 is still ahead.
                if modifier == .this && laterToday != false { return startOfToday }
                if modifier == .plain && laterToday == true { return startOfToday }
            }
            return upcoming(weekday: target, modifier: modifier, allowToday: false)
        case .date(let month, let dayValue, let year):
            let currentYear = calendar.component(.year, from: now)
            var components = DateComponents()
            components.year = year ?? currentYear
            components.month = month
            components.day = dayValue
            var date = calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? startOfToday
            if year == nil, date < startOfToday {
                components.year = currentYear + 1
                date = calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
            }
            return date
        case .dayOfMonth(let dayValue):
            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = dayValue
            var date = calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? startOfToday
            if date < startOfToday || (date == startOfToday && laterToday != true) {
                if let nextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now) {
                    var nextComponents = calendar.dateComponents([.year, .month], from: nextMonth)
                    nextComponents.day = dayValue
                    date = calendar.date(from: nextComponents).map { calendar.startOfDay(for: $0) } ?? date
                }
            }
            return date
        case .week(let offset):
            if offset == 0 { return startOfToday }
            // Monday of next week.
            let nextWeekStart = calendar.dateInterval(of: .weekOfYear, for: addDays(7, to: startOfToday))?.start ?? addDays(7, to: startOfToday)
            var monday = nextWeekStart
            while weekday(of: monday) != 2 { monday = addDays(1, to: monday) }
            return monday
        case .weekend(let offset):
            let today = weekday(of: now)
            if offset == 0 && (today == 7 || today == 1) { return startOfToday }
            var saturday = upcoming(weekday: 7, modifier: .plain, allowToday: true)
            if offset == 1 { saturday = addDays(7, to: saturday) }
            return saturday
        case .month(let offset):
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
            if offset == 0 { return startOfToday }
            return calendar.date(byAdding: .month, value: offset, to: monthStart) ?? monthStart
        case .endOfWeek:
            let today = weekday(of: now)
            if today == 6 { return startOfToday }
            return upcoming(weekday: 6, modifier: .plain, allowToday: true)
        case .endOfMonth:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            return addDays(-1, to: nextMonth)
        }
    }

    /// Resolves an hour given an optional meridiem, choosing the most plausible reading.
    func resolveClock(_ clock: ClockTime, on day: Date, period: Period?) -> (date: Date, approximate: Bool) {
        if clock.isMidnight {
            return (addDays(1, to: calendar.startOfDay(for: day)), false)
        }
        if let meridiem = clock.meridiem {
            var hour = clock.hour % 12
            if meridiem == .pm { hour += 12 }
            return (at(day, hour: hour, minute: clock.minute), false)
        }
        if clock.is24Hour || clock.hour == 0 || clock.hour > 12 {
            return (at(day, hour: clock.hour, minute: clock.minute), false)
        }
        if let period {
            switch period {
            case .morning, .firstThing:
                return (at(day, hour: clock.hour % 12, minute: clock.minute), false)
            case .afternoon, .evening, .endOfDay:
                return (at(day, hour: clock.hour % 12 + 12, minute: clock.minute), false)
            case .night:
                let hour = clock.hour == 12 ? 24 : (clock.hour < 5 ? clock.hour + 24 : clock.hour % 12 + 12)
                if hour >= 24 { return (at(addDays(1, to: day), hour: hour - 24, minute: clock.minute), false) }
                return (at(day, hour: hour, minute: clock.minute), false)
            }
        }
        let amHour = clock.hour % 12
        let pmHour = amHour + 12
        let amDate = at(day, hour: amHour, minute: clock.minute)
        let pmDate = at(day, hour: pmHour, minute: clock.minute)
        let awake = defaults.awakeStartHour..<defaults.awakeEndHour
        if calendar.isDate(day, inSameDayAs: now) {
            let candidates = [amDate, pmDate].filter { $0 > now }
            if let preferred = candidates.first(where: { awake.contains(calendar.component(.hour, from: $0)) }) {
                return (preferred, true)
            }
            if let next = candidates.first { return (next, true) }
            // Both readings passed: caller decides whether to roll to tomorrow.
            return (awake.contains(pmHour) ? pmDate : amDate, true)
        }
        // A future day: prefer waking hours (7–11 → morning, 12 → noon, 1–6 → afternoon/evening).
        if clock.hour == 12 { return (pmDate, true) }
        return (awake.contains(amHour) ? amDate : pmDate, true)
    }

    // MARK: Schedule resolution

    func resolveSchedule(offset: (SpokenDuration, Bool)?, day: DayRef?, time: ClockTime?, period: Period?,
                         periodImpliesToday: Bool, recurrence: RecurrenceRule?, consumed: Set<Int>) -> TemporalResult? {
        var approximate = false

        if let recurrence {
            let firstDay: Date
            var timeOfDay: (Int, Int)
            if let time {
                // Resolve am/pm as for a future day ("every day at 7" means 7 AM), not relative to now.
                let resolved = resolveClock(time, on: addDays(1, to: startOfToday), period: period)
                timeOfDay = (calendar.component(.hour, from: resolved.date), calendar.component(.minute, from: resolved.date))
                approximate = resolved.approximate
            } else if let period {
                timeOfDay = defaultHour(for: period)
            } else {
                timeOfDay = (defaults.dateOnlyHour, 0)
            }
            if time?.isMidnight == true { timeOfDay = (0, 0) }
            if !recurrence.weekdays.isEmpty {
                var candidate = startOfToday
                var found: Date?
                for offsetDays in 0..<14 {
                    candidate = addDays(offsetDays, to: startOfToday)
                    if recurrence.weekdays.contains(weekday(of: candidate)) {
                        let instant = at(candidate, hour: timeOfDay.0, minute: timeOfDay.1)
                        if instant > now { found = instant; break }
                    }
                }
                firstDay = found ?? at(addDays(7, to: startOfToday), hour: timeOfDay.0, minute: timeOfDay.1)
            } else {
                let todayInstant = at(startOfToday, hour: timeOfDay.0, minute: timeOfDay.1)
                firstDay = todayInstant > now ? todayInstant : at(addDays(1, to: startOfToday), hour: timeOfDay.0, minute: timeOfDay.1)
            }
            return TemporalResult(start: firstDay, end: nil, hasExplicitTime: time != nil || period != nil, hasExplicitDay: true,
                                  recurrence: recurrence, consumed: consumed, isInPast: false, isApproximate: approximate)
        }

        if let (duration, approx) = offset, day == nil {
            var instant = duration.added(to: now, calendar: calendar)
            var explicitTime = !duration.isDayScale
            if let time {
                let resolved = resolveClock(time, on: instant, period: period)
                instant = resolved.date
                explicitTime = true
                approximate = resolved.approximate
            } else if let period, duration.isDayScale {
                let (hour, minute) = defaultHour(for: period)
                instant = at(instant, hour: hour, minute: minute)
                explicitTime = true
            } else if duration.isDayScale {
                let hour = calendar.component(.hour, from: instant)
                if !(defaults.awakeStartHour..<defaults.awakeEndHour).contains(hour) {
                    instant = at(instant, hour: defaults.dateOnlyHour, minute: 0)
                }
            }
            return TemporalResult(start: instant, end: nil, hasExplicitTime: explicitTime, hasExplicitDay: true,
                                  recurrence: nil, consumed: consumed, isInPast: instant < now,
                                  isApproximate: approx || approximate)
        }

        // Day + optional time/period.
        let explicitDay = day != nil || periodImpliesToday
        var baseDay: Date
        if let day {
            let laterToday: Bool? = time.map { resolveClock($0, on: startOfToday, period: period).date > now }
            baseDay = resolveDay(day, laterToday: laterToday)
        } else {
            baseDay = startOfToday
        }

        var instant: Date
        var explicitTime = false
        if let time {
            let resolved = resolveClock(time, on: baseDay, period: period)
            instant = resolved.date
            approximate = resolved.approximate
            explicitTime = true
            if day == nil && !periodImpliesToday && instant <= now {
                // "at 9" when 9 has passed today → tomorrow.
                let tomorrow = addDays(1, to: baseDay)
                instant = resolveClock(time, on: tomorrow, period: period).date
            }
        } else if let period {
            let (hour, minute) = defaultHour(for: period)
            instant = at(baseDay, hour: hour, minute: minute)
            explicitTime = true
            if day == nil && !periodImpliesToday && instant <= now {
                instant = at(addDays(1, to: baseDay), hour: hour, minute: minute)
            } else if periodImpliesToday && instant <= now {
                // "this afternoon" when afternoon has started: an hour from now, still that afternoon.
                let (_, periodEnd) = periodInterval(period, on: baseDay)
                let soon = roundedUp(now.addingTimeInterval(3_600))
                if soon < periodEnd { instant = soon; approximate = true }
            }
        } else if let day {
            switch day {
            case .relative(0):
                // "today" with no time: late afternoon, or an hour from now if that has passed.
                let target = at(baseDay, hour: defaults.endOfDayHour, minute: 0)
                instant = target > now ? target : roundedUp(now.addingTimeInterval(3_600))
                approximate = true
            case .weekend:
                instant = at(baseDay, hour: defaults.weekendHour, minute: 0)
            case .endOfWeek, .endOfMonth:
                instant = at(baseDay, hour: defaults.endOfDayHour, minute: 0)
            case .week(offset: 0), .month(offset: 0):
                instant = roundedUp(now.addingTimeInterval(3_600))
                approximate = true
            default:
                instant = at(baseDay, hour: defaults.dateOnlyHour, minute: 0)
            }
            if instant <= now && calendar.isDate(baseDay, inSameDayAs: now) {
                instant = roundedUp(now.addingTimeInterval(3_600))
                approximate = true
            }
        } else {
            return nil
        }
        return TemporalResult(start: instant, end: nil, hasExplicitTime: explicitTime, hasExplicitDay: explicitDay,
                              recurrence: nil, consumed: consumed, isInPast: instant < now, isApproximate: approximate)
    }

    /// Rounds up to the next quarter hour.
    func roundedUp(_ date: Date) -> Date {
        let minute = calendar.component(.minute, from: date)
        let remainder = minute % 15
        let add = remainder == 0 ? 0 : 15 - remainder
        let rounded = date.addingTimeInterval(Double(add) * 60)
        return calendar.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    // MARK: Query resolution

    func resolveQuery(offset: (SpokenDuration, Bool)?, day: DayRef?, time: ClockTime?, period: Period?,
                      periodImpliesToday: Bool, consumed: Set<Int>) -> TemporalResult? {
        if let (duration, approx) = offset, day == nil {
            let point = duration.added(to: now, calendar: calendar)
            return TemporalResult(start: point, end: point.addingTimeInterval(3_600), hasExplicitTime: true, hasExplicitDay: true,
                                  recurrence: nil, consumed: consumed, isInPast: false, isApproximate: approx)
        }
        var start: Date
        var end: Date
        var explicitDay = day != nil || periodImpliesToday
        if let day {
            switch day {
            case .week(let weekOffset):
                if weekOffset == 0 {
                    start = now
                    end = calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? addDays(7, to: startOfToday)
                } else {
                    let next = calendar.dateInterval(of: .weekOfYear, for: addDays(7, to: startOfToday))
                    start = next?.start ?? addDays(7, to: startOfToday)
                    end = next?.end ?? addDays(14, to: startOfToday)
                }
                return TemporalResult(start: start, end: end, hasExplicitTime: false, hasExplicitDay: true, recurrence: nil,
                                      consumed: consumed, isInPast: false, isApproximate: false)
            case .weekend(let weekendOffset):
                let today = weekday(of: now)
                var saturday: Date
                if today == 7 { saturday = startOfToday }
                else if today == 1 { saturday = addDays(-1, to: startOfToday) }
                else { saturday = upcoming(weekday: 7, modifier: .plain, allowToday: false) }
                if weekendOffset == 1 { saturday = addDays(7, to: saturday) }
                start = weekendOffset == 0 ? max(saturday, startOfToday) : saturday
                end = addDays(2, to: saturday)
                return TemporalResult(start: start, end: end, hasExplicitTime: false, hasExplicitDay: true, recurrence: nil,
                                      consumed: consumed, isInPast: false, isApproximate: false)
            case .month(let monthOffset):
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfToday
                let targetStart = calendar.date(byAdding: .month, value: monthOffset, to: monthStart) ?? monthStart
                start = monthOffset == 0 ? now : targetStart
                end = calendar.date(byAdding: .month, value: 1, to: targetStart) ?? addDays(30, to: targetStart)
                return TemporalResult(start: start, end: end, hasExplicitTime: false, hasExplicitDay: true, recurrence: nil,
                                      consumed: consumed, isInPast: false, isApproximate: false)
            default:
                start = resolveDay(day, laterToday: nil)
            }
        } else {
            start = startOfToday
            explicitDay = periodImpliesToday
        }

        let dayStart = calendar.startOfDay(for: start)
        if let time {
            let resolved = resolveClock(time, on: dayStart, period: period)
            return TemporalResult(start: resolved.date, end: resolved.date.addingTimeInterval(3_600), hasExplicitTime: true,
                                  hasExplicitDay: explicitDay, recurrence: nil, consumed: consumed,
                                  isInPast: resolved.date < now, isApproximate: resolved.approximate)
        }
        if let period {
            let (periodStart, periodEnd) = periodInterval(period, on: dayStart)
            return TemporalResult(start: periodStart, end: periodEnd, hasExplicitTime: false, hasExplicitDay: true,
                                  recurrence: nil, consumed: consumed, isInPast: periodEnd < now, isApproximate: false)
        }
        end = addDays(1, to: dayStart)
        start = dayStart
        return TemporalResult(start: start, end: end, hasExplicitTime: false, hasExplicitDay: explicitDay,
                              recurrence: nil, consumed: consumed, isInPast: end < now, isApproximate: false)
    }
}
