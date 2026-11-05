import Foundation

/// A spoken span of time, e.g. "an hour and a half" or "30 days".
///
/// Calendar units (days, weeks, months, years) are kept separate from clock units so
/// "in 30 days" lands on the same wall-clock time across daylight-saving changes.
public struct SpokenDuration: Sendable, Hashable {
    public var seconds: Double = 0
    public var days: Int = 0
    public var months: Int = 0
    public var years: Int = 0

    public init(seconds: Double = 0, days: Int = 0, months: Int = 0, years: Int = 0) {
        self.seconds = seconds
        self.days = days
        self.months = months
        self.years = years
    }

    public var isZero: Bool { seconds == 0 && days == 0 && months == 0 && years == 0 }

    /// True when the duration only uses clock units (suitable for timers).
    public var isClockOnly: Bool { days == 0 && months == 0 && years == 0 }

    /// Approximate length in seconds (months as 30 days, years as 365 days).
    public var approximateSeconds: Double {
        seconds + Double(days) * 86_400 + Double(months) * 30 * 86_400 + Double(years) * 365 * 86_400
    }

    /// True when the duration is at least one day (so a default time of day may apply).
    public var isDayScale: Bool { days > 0 || months > 0 || years > 0 }

    public func added(to date: Date, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = years == 0 ? nil : years
        components.month = months == 0 ? nil : months
        components.day = days == 0 ? nil : days
        var result = calendar.date(byAdding: components, to: date) ?? date
        result = result.addingTimeInterval(seconds)
        return result
    }

    public static func + (lhs: SpokenDuration, rhs: SpokenDuration) -> SpokenDuration {
        SpokenDuration(seconds: lhs.seconds + rhs.seconds, days: lhs.days + rhs.days,
                       months: lhs.months + rhs.months, years: lhs.years + rhs.years)
    }
}

public enum DurationUnit: Sendable {
    case second, minute, hour, day, week, month, year

    static func from(_ word: String) -> DurationUnit? {
        switch word {
        case "second", "seconds", "sec", "secs", "s": return .second
        case "minute", "minutes", "min", "mins", "m": return .minute
        case "hour", "hours", "hr", "hrs", "h": return .hour
        case "day", "days", "d": return .day
        case "week", "weeks", "wk", "wks": return .week
        case "month", "months": return .month
        case "year", "years", "yr", "yrs": return .year
        default: return nil
        }
    }

    func duration(_ amount: Double) -> SpokenDuration {
        switch self {
        case .second: return SpokenDuration(seconds: amount)
        case .minute: return SpokenDuration(seconds: amount * 60)
        case .hour: return SpokenDuration(seconds: amount * 3_600)
        case .day:
            let whole = Int(amount)
            return SpokenDuration(seconds: (amount - Double(whole)) * 86_400, days: whole)
        case .week:
            let days = amount * 7
            let whole = Int(days)
            return SpokenDuration(seconds: (days - Double(whole)) * 86_400, days: whole)
        case .month:
            let whole = Int(amount)
            return SpokenDuration(days: Int(((amount - Double(whole)) * 30).rounded()), months: whole)
        case .year:
            let whole = Int(amount)
            return SpokenDuration(months: Int(((amount - Double(whole)) * 12).rounded()), years: whole)
        }
    }
}

/// Parses durations from normalized tokens.
public enum DurationParser {
    /// Attempts to read a duration starting at `start`. Returns the duration and the end index (exclusive).
    public static func parse(_ norms: [String], at start: Int) -> (duration: SpokenDuration, end: Int)? {
        var index = start
        var total = SpokenDuration()
        var matchedAny = false
        while index < norms.count {
            guard let (piece, next) = parseSingle(norms, at: index) else { break }
            total = total + piece
            matchedAny = true
            index = next
            // Allow "1 hour and 30 minutes" / "1 hour 30 minutes".
            if index < norms.count, norms[index] == "and",
               index + 1 < norms.count, parseSingle(norms, at: index + 1) != nil {
                index += 1
            }
        }
        return matchedAny && !total.isZero ? (total, index) : nil
    }

    /// Parses an entire token list as a duration (e.g. a timer request's remainder).
    public static func parseWhole(_ norms: [String]) -> SpokenDuration? {
        guard let (duration, end) = parse(norms, at: 0), end == norms.count else { return nil }
        return duration
    }

    static func amount(_ norms: [String], at index: Int) -> (Double, Int)? {
        guard index < norms.count else { return nil }
        let word = norms[index]
        if let value = NumberWords.numeric(word), !word.contains(":") { return (value, index + 1) }
        switch word {
        case "a", "an", "one":
            // "a couple (of)", "a few", plain "a"
            if index + 1 < norms.count {
                if norms[index + 1] == "couple" {
                    let next = index + 2 < norms.count && norms[index + 2] == "of" ? index + 3 : index + 2
                    return (2, next)
                }
                if norms[index + 1] == "few" { return (3, index + 2) }
            }
            return (1, index + 1)
        case "couple":
            let next = index + 1 < norms.count && norms[index + 1] == "of" ? index + 2 : index + 1
            return (2, next)
        case "few", "several":
            return (3, index + 1)
        default:
            return nil
        }
    }

    static func parseSingle(_ norms: [String], at start: Int) -> (SpokenDuration, Int)? {
        guard start < norms.count else { return nil }

        // "half an hour", "half a minute", "half a day"
        if norms[start] == "half", start + 2 < norms.count, ["a", "an"].contains(norms[start + 1]),
           let unit = DurationUnit.from(norms[start + 2]) {
            return (unit.duration(0.5), start + 3)
        }
        // "a quarter of an hour", "quarter hour", "quarter of an hour"
        var quarterStart = start
        if norms[start] == "a", start + 1 < norms.count, norms[start + 1] == "quarter" { quarterStart = start + 1 }
        if norms[quarterStart] == "quarter" {
            var index = quarterStart + 1
            if index < norms.count, norms[index] == "of" { index += 1 }
            if index < norms.count, ["a", "an"].contains(norms[index]) { index += 1 }
            if index < norms.count, norms[index] == "hour" || norms[index] == "hours" {
                return (SpokenDuration(seconds: 900), index + 1)
            }
        }

        guard let (value, afterAmount) = amount(norms, at: start) else { return nil }
        var amountValue = value
        var index = afterAmount
        // "2 and a half hours"
        if index + 2 < norms.count, norms[index] == "and", norms[index + 1] == "a", norms[index + 2] == "half" {
            amountValue += 0.5
            index += 3
        }
        guard index < norms.count, let unit = DurationUnit.from(norms[index]) else { return nil }
        // Single-letter units are only accepted right after a numeral ("5 m" is too ambiguous otherwise).
        if norms[index].count == 1, NumberWords.numeric(norms[start]) == nil { return nil }
        index += 1
        var duration = unit.duration(amountValue)
        // "an hour and a half"
        if index + 2 < norms.count, norms[index] == "and", norms[index + 1] == "a", norms[index + 2] == "half" {
            duration = duration + unit.duration(0.5)
            index += 3
        }
        return (duration, index)
    }
}
