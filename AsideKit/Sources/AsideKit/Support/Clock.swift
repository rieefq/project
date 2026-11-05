import Foundation

/// Source of "now". Injected everywhere time matters so behavior is deterministic in tests.
public protocol AgentClock: Sendable {
    var now: Date { get }
}

public struct SystemClock: AgentClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock whose time is set explicitly. Thread-safe.
public final class ManualClock: AgentClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ date: Date) { current = date }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func set(_ date: Date) {
        lock.lock(); current = date; lock.unlock()
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

/// Calendar and locale context for interpreting and speaking dates.
public struct TemporalContext: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var timeZone: TimeZone { calendar.timeZone }

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        var cal = calendar
        cal.locale = locale
        self.calendar = cal
        self.locale = locale
    }

    /// True when the locale writes times with a 12-hour clock.
    public var uses12HourClock: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h a"
        return format.contains("a") || format.contains("h") || format.contains("K")
    }
}

/// Small helper for identifiers that read well in logs and journals.
public enum Identifier {
    public static func make(_ prefix: String) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)_\(raw.prefix(16))"
    }
}
