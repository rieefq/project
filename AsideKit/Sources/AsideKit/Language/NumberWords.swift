import Foundation

/// Converts spoken English numbers ("twenty five", "a hundred and ten", "third") into values.
public enum NumberWords {
    static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
    ]

    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    static let scales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]

    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    /// Ordinal tens prefixes like "twenty" in "twenty first".
    static let ordinalTens: [String: Int] = ["twenty": 20, "thirty": 30]

    public static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || tens[word] != nil || scales[word] != nil
    }

    /// Value of a cardinal number word sequence, e.g. ["one", "hundred", "and", "five"] → 105.
    public static func cardinal(_ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        var total = 0
        var current = 0
        var sawNumber = false
        for (index, word) in words.enumerated() {
            if let value = units[word] {
                current += value; sawNumber = true
            } else if let value = tens[word] {
                current += value; sawNumber = true
            } else if word == "hundred" {
                current = max(current, 1) * 100; sawNumber = true
            } else if let scale = scales[word] {
                total += max(current, 1) * scale; current = 0; sawNumber = true
            } else if word == "and", index > 0, index < words.count - 1 {
                continue
            } else if (word == "a" || word == "an"), index == 0, words.count > 1, scales[words[1]] != nil {
                current = 1
            } else {
                return nil
            }
        }
        return sawNumber ? total + current : nil
    }

    /// Value of an ordinal sequence, e.g. ["twenty", "first"] → 21, ["3rd"] → 3.
    public static func ordinal(_ words: [String]) -> Int? {
        if words.count == 1 {
            let word = words[0]
            if let value = ordinals[word] { return value }
            return numericOrdinal(word)
        }
        if words.count == 2, let tensValue = ordinalTens[words[0]], let unit = ordinals[words[1]], unit < 10 {
            return tensValue + unit
        }
        return nil
    }

    /// Parses "3rd", "21st", "2nd", "4th" into 3, 21, 2, 4.
    public static func numericOrdinal(_ word: String) -> Int? {
        for suffix in ["st", "nd", "rd", "th"] where word.hasSuffix(suffix) {
            return Int(word.dropLast(2))
        }
        return nil
    }

    /// Suffix for an ordinal value, e.g. 1 → "st", 12 → "th", 23 → "rd".
    public static func ordinalSuffix(_ value: Int) -> String {
        let tens = (value / 10) % 10
        if tens == 1 { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Parses a numeric token: "30", "2.5", "1,000", "30%" (as 30).
    public static func numeric(_ token: String) -> Double? {
        var cleaned = token.replacingOccurrences(of: ",", with: "")
        if cleaned.hasSuffix("%") { cleaned.removeLast() }
        if cleaned.hasPrefix("$") { cleaned.removeFirst() }
        guard !cleaned.isEmpty, cleaned.first != "." || cleaned.count > 1 else { return nil }
        return Double(cleaned)
    }
}
