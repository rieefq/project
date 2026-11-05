import Foundation

/// Evaluates spoken arithmetic: "18 percent of 64", "3 plus 4 times 2", "square root of 81".
public enum Calculator {
    public struct Answer: Sendable, Hashable {
        public var value: Double
        public var spokenExpression: String
    }

    public static func evaluate(_ text: String) -> Answer? {
        let tokens = symbolize(Utterance(text).norms)
        guard !tokens.isEmpty, tokens.contains(where: { Double($0) != nil }),
              tokens.contains(where: { ["+", "-", "*", "/", "^", "%of", "%", "sqrt"].contains($0) }) else { return nil }
        var parser = ExpressionParser(tokens: tokens)
        guard let value = parser.parseExpression(), parser.isAtEnd, value.isFinite else { return nil }
        return Answer(value: value, spokenExpression: text)
    }

    /// Maps spoken words to operator symbols and drops filler.
    static func symbolize(_ words: [String]) -> [String] {
        var output: [String] = []
        var index = 0
        func peek(_ offset: Int) -> String? { index + offset < words.count ? words[index + offset] : nil }
        while index < words.count {
            let word = words[index]
            switch word {
            case "plus", "+", "add": output.append("+")
            case "minus", "-", "less", "subtract": output.append("-")
            case "times", "x", "*", "×": output.append("*")
            case "multiplied":
                output.append("*"); if peek(1) == "by" { index += 1 }
            case "divided":
                output.append("/"); if peek(1) == "by" { index += 1 }
            case "over", "/", "÷": output.append("/")
            case "squared": output.append(contentsOf: ["^", "2"])
            case "cubed": output.append(contentsOf: ["^", "3"])
            case "to" where peek(1) == "the" && peek(2) == "power" && peek(3) == "of":
                output.append("^"); index += 3
            case "raised" where peek(1) == "to":
                output.append("^"); index += 1
                if peek(1) == "the" && peek(2) == "power" && peek(3) == "of" { index += 3 }
            case "square" where peek(1) == "root":
                output.append("sqrt"); index += 1
                if peek(1) == "of" { index += 1 }
            case "percent", "%":
                if peek(1) == "of" { output.append("%of"); index += 1 } else { output.append("%") }
            case "half" where peek(1) == "of":
                output.append(contentsOf: ["0.5", "*"]); index += 1
            case "(", ")": output.append(word)
            case "point":
                // "3 point 5" → 3.5
                if let last = output.last, Double(last) != nil, let next = peek(1), Int(next) != nil {
                    output[output.count - 1] = last + "." + next
                    index += 1
                }
            case "what's", "what", "is", "calculate", "equals", "equal", "the", "of", "how", "much", "compute", "a", "are", "by", "?", "=":
                break
            default:
                if word.hasSuffix("%"), let value = NumberWords.numeric(word) {
                    output.append(String(value))
                    if peek(1) == "of" { output.append("%of"); index += 1 } else { output.append("%") }
                } else if let value = NumberWords.numeric(word) {
                    output.append(String(value))
                } else {
                    return [] // unknown word: not pure arithmetic
                }
            }
            index += 1
        }
        return output
    }

    struct ExpressionParser {
        var tokens: [String]
        var position = 0

        var isAtEnd: Bool { position >= tokens.count }

        mutating func next() -> String? {
            guard position < tokens.count else { return nil }
            defer { position += 1 }
            return tokens[position]
        }

        func peek() -> String? { position < tokens.count ? tokens[position] : nil }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                position += 1
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parsePower() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%of" {
                position += 1
                guard let rhs = parsePower() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/":
                    guard rhs != 0 else { return nil }
                    value /= rhs
                default: value = value / 100 * rhs
                }
            }
            return value
        }

        mutating func parsePower() -> Double? {
            guard let base = parseUnary() else { return nil }
            if peek() == "^" {
                position += 1
                guard let exponent = parsePower() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func parseUnary() -> Double? {
            if peek() == "-" { position += 1; return parseUnary().map { -$0 } }
            if peek() == "sqrt" {
                position += 1
                guard let value = parseUnary(), value >= 0 else { return nil }
                return sqrt(value)
            }
            guard var value = parsePrimary() else { return nil }
            if peek() == "%" { position += 1; value /= 100 }
            return value
        }

        mutating func parsePrimary() -> Double? {
            guard let token = next() else { return nil }
            if token == "(" {
                let value = parseExpression()
                guard next() == ")" else { return nil }
                return value
            }
            return Double(token)
        }
    }
}

/// Converts between common units: "5 km in miles", "how many ounces in a cup", "72 fahrenheit in celsius".
public enum UnitConverter {
    public struct Conversion: Sendable, Hashable {
        public var value: Double
        public var fromName: String
        public var result: Double
        public var toName: String
    }

    struct UnitInfo {
        var dimension: Dimension
        var singular: String
        var plural: String
        var kind: String
    }

    static func unit(_ word: String, preferVolume: Bool = false) -> UnitInfo? {
        switch word {
        case "km", "kilometer", "kilometers", "kilometre", "kilometres": return UnitInfo(dimension: UnitLength.kilometers, singular: "kilometer", plural: "kilometers", kind: "length")
        case "mile", "miles", "mi": return UnitInfo(dimension: UnitLength.miles, singular: "mile", plural: "miles", kind: "length")
        case "meter", "meters", "metre", "metres", "m": return UnitInfo(dimension: UnitLength.meters, singular: "meter", plural: "meters", kind: "length")
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres": return UnitInfo(dimension: UnitLength.centimeters, singular: "centimeter", plural: "centimeters", kind: "length")
        case "mm", "millimeter", "millimeters": return UnitInfo(dimension: UnitLength.millimeters, singular: "millimeter", plural: "millimeters", kind: "length")
        case "inch", "inches", "in.": return UnitInfo(dimension: UnitLength.inches, singular: "inch", plural: "inches", kind: "length")
        case "foot", "feet", "ft": return UnitInfo(dimension: UnitLength.feet, singular: "foot", plural: "feet", kind: "length")
        case "yard", "yards", "yd": return UnitInfo(dimension: UnitLength.yards, singular: "yard", plural: "yards", kind: "length")
        case "kg", "kilogram", "kilograms", "kilo", "kilos": return UnitInfo(dimension: UnitMass.kilograms, singular: "kilogram", plural: "kilograms", kind: "mass")
        case "g", "gram", "grams": return UnitInfo(dimension: UnitMass.grams, singular: "gram", plural: "grams", kind: "mass")
        case "lb", "lbs", "pound", "pounds": return UnitInfo(dimension: UnitMass.pounds, singular: "pound", plural: "pounds", kind: "mass")
        case "oz", "ounce", "ounces":
            return preferVolume
                ? UnitInfo(dimension: UnitVolume.fluidOunces, singular: "fluid ounce", plural: "fluid ounces", kind: "volume")
                : UnitInfo(dimension: UnitMass.ounces, singular: "ounce", plural: "ounces", kind: "mass")
        case "stone", "stones": return UnitInfo(dimension: UnitMass.stones, singular: "stone", plural: "stone", kind: "mass")
        case "liter", "liters", "litre", "litres", "l": return UnitInfo(dimension: UnitVolume.liters, singular: "liter", plural: "liters", kind: "volume")
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres": return UnitInfo(dimension: UnitVolume.milliliters, singular: "milliliter", plural: "milliliters", kind: "volume")
        case "cup", "cups": return UnitInfo(dimension: UnitVolume.cups, singular: "cup", plural: "cups", kind: "volume")
        case "tablespoon", "tablespoons", "tbsp": return UnitInfo(dimension: UnitVolume.tablespoons, singular: "tablespoon", plural: "tablespoons", kind: "volume")
        case "teaspoon", "teaspoons", "tsp": return UnitInfo(dimension: UnitVolume.teaspoons, singular: "teaspoon", plural: "teaspoons", kind: "volume")
        case "gallon", "gallons": return UnitInfo(dimension: UnitVolume.gallons, singular: "gallon", plural: "gallons", kind: "volume")
        case "quart", "quarts": return UnitInfo(dimension: UnitVolume.quarts, singular: "quart", plural: "quarts", kind: "volume")
        case "pint", "pints": return UnitInfo(dimension: UnitVolume.pints, singular: "pint", plural: "pints", kind: "volume")
        case "celsius", "centigrade", "c": return UnitInfo(dimension: UnitTemperature.celsius, singular: "degree Celsius", plural: "degrees Celsius", kind: "temperature")
        case "fahrenheit", "f": return UnitInfo(dimension: UnitTemperature.fahrenheit, singular: "degree Fahrenheit", plural: "degrees Fahrenheit", kind: "temperature")
        case "kelvin": return UnitInfo(dimension: UnitTemperature.kelvin, singular: "kelvin", plural: "kelvin", kind: "temperature")
        case "mph": return UnitInfo(dimension: UnitSpeed.milesPerHour, singular: "mile per hour", plural: "miles per hour", kind: "speed")
        case "kph", "km/h", "kmh": return UnitInfo(dimension: UnitSpeed.kilometersPerHour, singular: "kilometer per hour", plural: "kilometers per hour", kind: "speed")
        default: return nil
        }
    }

    public static func mentionsUnits(_ norms: [String]) -> Bool {
        norms.filter { unit($0) != nil && $0.count > 1 }.count >= 2
    }

    public static func convert(_ text: String) -> Conversion? {
        var words = Utterance(text).norms.filter { !["what's", "what", "is", "convert", "how", "many", "much", "are", "there", "the", "degrees", "degree", "?"].contains($0) }
        // "a cup" → "1 cup"
        words = words.map { $0 == "a" || $0 == "an" || $0 == "one" ? "1" : $0 }
        guard let separator = words.firstIndex(where: { ["in", "to", "into", "as"].contains($0) }) else { return nil }
        let left = Array(words[..<separator])
        let right = Array(words[(separator + 1)...])
        // Either "5 km in miles" or "ounces in 1 cup" (how many X in Y)
        func valueAndUnit(_ part: [String]) -> (Double?, String?) {
            var value: Double?
            var unitWord: String?
            for word in part {
                if value == nil, let number = NumberWords.numeric(word) { value = number; continue }
                if unitWord == nil, unit(word) != nil { unitWord = word }
            }
            return (value, unitWord)
        }
        let (leftValue, leftUnit) = valueAndUnit(left)
        let (rightValue, rightUnit) = valueAndUnit(right)
        guard let leftUnit, let rightUnit else { return nil }
        let fromWord: String, toWord: String, amount: Double
        if let leftValue {
            fromWord = leftUnit; toWord = rightUnit; amount = leftValue
        } else {
            fromWord = rightUnit; toWord = leftUnit; amount = rightValue ?? 1
        }
        let involvesVolume = [fromWord, toWord].contains { unit($0)?.kind == "volume" }
        guard let from = unit(fromWord, preferVolume: involvesVolume), let to = unit(toWord, preferVolume: involvesVolume),
              from.kind == to.kind else { return nil }
        let measurement = Measurement(value: amount, unit: from.dimension)
        let converted = measurement.converted(to: to.dimension)
        return Conversion(value: amount, fromName: amount == 1 ? from.singular : from.plural,
                          result: converted.value, toName: abs(converted.value - 1) < 0.0001 ? to.singular : to.plural)
    }
}

/// Time-zone lookup for "what time is it in Tokyo?"
public enum WorldClock {
    static let places: [String: String] = [
        "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "osaka": "Asia/Tokyo", "seoul": "Asia/Seoul", "korea": "Asia/Seoul",
        "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai", "china": "Asia/Shanghai", "hong kong": "Asia/Hong_Kong",
        "singapore": "Asia/Singapore", "jakarta": "Asia/Jakarta", "indonesia": "Asia/Jakarta", "bali": "Asia/Makassar",
        "bangkok": "Asia/Bangkok", "manila": "Asia/Manila", "kuala lumpur": "Asia/Kuala_Lumpur", "taipei": "Asia/Taipei",
        "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "india": "Asia/Kolkata",
        "dubai": "Asia/Dubai", "abu dhabi": "Asia/Dubai", "riyadh": "Asia/Riyadh", "tel aviv": "Asia/Jerusalem", "jerusalem": "Asia/Jerusalem",
        "istanbul": "Europe/Istanbul", "moscow": "Europe/Moscow", "london": "Europe/London", "uk": "Europe/London", "england": "Europe/London",
        "dublin": "Europe/Dublin", "lisbon": "Europe/Lisbon", "paris": "Europe/Paris", "france": "Europe/Paris", "berlin": "Europe/Berlin",
        "germany": "Europe/Berlin", "munich": "Europe/Berlin", "amsterdam": "Europe/Amsterdam", "brussels": "Europe/Brussels",
        "madrid": "Europe/Madrid", "barcelona": "Europe/Madrid", "spain": "Europe/Madrid", "rome": "Europe/Rome", "milan": "Europe/Rome",
        "italy": "Europe/Rome", "zurich": "Europe/Zurich", "vienna": "Europe/Vienna", "stockholm": "Europe/Stockholm", "oslo": "Europe/Oslo",
        "copenhagen": "Europe/Copenhagen", "helsinki": "Europe/Helsinki", "athens": "Europe/Athens", "warsaw": "Europe/Warsaw",
        "prague": "Europe/Prague", "cairo": "Africa/Cairo", "lagos": "Africa/Lagos", "nairobi": "Africa/Nairobi",
        "johannesburg": "Africa/Johannesburg", "cape town": "Africa/Johannesburg", "new york": "America/New_York", "nyc": "America/New_York",
        "boston": "America/New_York", "washington": "America/New_York", "dc": "America/New_York", "miami": "America/New_York",
        "atlanta": "America/New_York", "toronto": "America/Toronto", "montreal": "America/Toronto", "chicago": "America/Chicago",
        "houston": "America/Chicago", "dallas": "America/Chicago", "austin": "America/Chicago", "denver": "America/Denver",
        "phoenix": "America/Phoenix", "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
        "sf": "America/Los_Angeles", "seattle": "America/Los_Angeles", "vancouver": "America/Vancouver", "portland": "America/Los_Angeles",
        "san diego": "America/Los_Angeles", "las vegas": "America/Los_Angeles", "anchorage": "America/Anchorage", "honolulu": "Pacific/Honolulu",
        "hawaii": "Pacific/Honolulu", "mexico city": "America/Mexico_City", "sao paulo": "America/Sao_Paulo", "são paulo": "America/Sao_Paulo",
        "rio": "America/Sao_Paulo", "buenos aires": "America/Argentina/Buenos_Aires", "bogota": "America/Bogota", "lima": "America/Lima",
        "santiago": "America/Santiago", "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "brisbane": "Australia/Brisbane",
        "perth": "Australia/Perth", "auckland": "Pacific/Auckland", "new zealand": "Pacific/Auckland",
    ]

    public static func timeZone(for place: String) -> TimeZone? {
        let key = place.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let identifier = places[key] { return TimeZone(identifier: identifier) }
        if let match = places.first(where: { key.hasSuffix($0.key) || key.hasPrefix($0.key + " ") }) {
            return TimeZone(identifier: match.value)
        }
        // Accept identifiers and abbreviations ("UTC", "PST", "Europe/Paris").
        return TimeZone(identifier: place) ?? TimeZone(abbreviation: place.uppercased())
    }
}
