import Foundation

/// One spoken word as recognized (`original`) and in canonical form (`norm`).
///
/// Grammar matching works on `norm` ("25", "pm", "what's"); anything we hand back to the
/// user — a reminder title, a message body — is rebuilt from `original` so casing,
/// names and punctuation from the recognizer are preserved.
public struct Token: Sendable, Hashable, CustomStringConvertible {
    public var original: String
    public var norm: String

    public init(original: String, norm: String) {
        self.original = original
        self.norm = norm
    }

    public var description: String { norm }
}

/// A tokenized utterance.
public struct Utterance: Sendable, Hashable {
    public let raw: String
    public let tokens: [Token]

    public init(_ raw: String) {
        self.raw = raw
        self.tokens = Tokenizer.tokenize(raw)
    }

    public init(raw: String, tokens: [Token]) {
        self.raw = raw
        self.tokens = tokens
    }

    public var norms: [String] { tokens.map(\.norm) }
    public var normalizedText: String { norms.joined(separator: " ") }
    public var isEmpty: Bool { tokens.isEmpty }
    public var count: Int { tokens.count }

    /// Original text for a token range.
    public func original(_ range: Range<Int>) -> String {
        let clamped = range.clamped(to: 0..<tokens.count)
        return tokens[clamped].map(\.original).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Original text for a token range, skipping excluded indices.
    public func original(_ range: Range<Int>, excluding excluded: Set<Int>) -> String {
        let clamped = range.clamped(to: 0..<tokens.count)
        return clamped.filter { !excluded.contains($0) }
            .map { tokens[$0].original }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Index of the first occurrence of a normalized phrase at or after `start`.
    public func find(_ phrase: [String], from start: Int = 0) -> Int? {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return nil }
        let norms = self.norms
        var index = start
        while index + phrase.count <= norms.count {
            if Array(norms[index..<(index + phrase.count)]) == phrase { return index }
            index += 1
        }
        return nil
    }

    public func hasPrefix(_ phrase: [String]) -> Bool {
        guard tokens.count >= phrase.count else { return false }
        return Array(norms.prefix(phrase.count)) == phrase
    }

    /// Returns a new utterance made of a sub-range of tokens.
    public func slice(_ range: Range<Int>) -> Utterance {
        let clamped = range.clamped(to: 0..<tokens.count)
        let sliced = Array(tokens[clamped])
        return Utterance(raw: sliced.map(\.original).joined(separator: " "), tokens: sliced)
    }

    /// Returns a new utterance without the excluded indices.
    public func removing(_ excluded: Set<Int>) -> Utterance {
        let kept = tokens.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
        return Utterance(raw: kept.map(\.original).joined(separator: " "), tokens: kept)
    }
}

/// Tokenizes recognizer output into normalized tokens.
public enum Tokenizer {
    static let separators: Set<Character> = [",", ";", "!", "?", "\"", "(", ")", "[", "]", "{", "}", "…", "“", "”", "—", "–"]

    static let fillers: Set<String> = ["um", "uh", "umm", "uhh", "er", "erm", "hmm", "mm"]

    public static func tokenize(_ text: String) -> [Token] {
        var cleaned = text
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        // Normalize a.m./p.m. variants before splitting.
        for (pattern, replacement) in [("a.m.", "am"), ("p.m.", "pm"), ("A.M.", "AM"), ("P.M.", "PM"), ("a. m.", "am"), ("p. m.", "pm")] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: replacement)
        }

        var pieces: [String] = []
        var current = ""
        let characters = Array(cleaned)
        for (index, character) in characters.enumerated() {
            if character.isWhitespace || separators.contains(character) {
                if !current.isEmpty { pieces.append(current); current = "" }
                continue
            }
            if character == "." {
                // Keep decimal points between digits; otherwise it ends a word.
                let previousIsDigit = index > 0 && characters[index - 1].isNumber
                let nextIsDigit = index + 1 < characters.count && characters[index + 1].isNumber
                if previousIsDigit && nextIsDigit { current.append(character); continue }
                if !current.isEmpty { pieces.append(current); current = "" }
                continue
            }
            if character == "-" {
                // Split hyphenated number words ("twenty-five") and ranges; keep other compounds.
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                let lowered = current.lowercased()
                if NumberWords.isNumberWord(lowered) || lowered.allSatisfy(\.isNumber) && !lowered.isEmpty && next.isLetter {
                    if !current.isEmpty { pieces.append(current); current = "" }
                    continue
                }
                if current.isEmpty || !next.isLetter && !next.isNumber {
                    if !current.isEmpty { pieces.append(current); current = "" }
                    continue
                }
            }
            if character == ":" {
                // Keep times like 5:30; drop trailing colons ("note: ...").
                let previousIsDigit = index > 0 && characters[index - 1].isNumber
                let nextIsDigit = index + 1 < characters.count && characters[index + 1].isNumber
                if previousIsDigit && nextIsDigit { current.append(character); continue }
                if !current.isEmpty { pieces.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }

        var tokens: [Token] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: CharacterSet(charactersIn: "'`*_#"))
            guard !trimmed.isEmpty else { continue }
            var norm = trimmed.lowercased()
            if norm == "o'clock" || norm == "oclock" { norm = "oclock" }
            if fillers.contains(norm) { continue }
            // Split glued meridiems: "5pm" → "5" "pm", "5:30am" → "5:30" "am".
            if let split = splitMeridiem(norm), split.count == 2 {
                let originalNumber = String(trimmed.dropLast(2))
                tokens.append(Token(original: originalNumber, norm: split[0]))
                tokens.append(Token(original: String(trimmed.suffix(2)), norm: split[1]))
                continue
            }
            tokens.append(Token(original: trimmed, norm: norm))
        }
        return mergeNumberWords(tokens)
    }

    static func splitMeridiem(_ word: String) -> [String]? {
        for suffix in ["am", "pm"] where word.hasSuffix(suffix) && word.count > 2 {
            let head = String(word.dropLast(2))
            let isTime = head.allSatisfy { $0.isNumber || $0 == ":" } && head.first?.isNumber == true
            if isTime { return [head, suffix] }
        }
        return nil
    }

    /// Collapses runs of cardinal number words into digit tokens, and ordinals into "3rd" form.
    static func mergeNumberWords(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < tokens.count {
            let word = tokens[index].norm
            // Ordinals: "twenty first" / "third".
            if index + 1 < tokens.count, NumberWords.ordinalTens[word] != nil,
               let value = NumberWords.ordinal([word, tokens[index + 1].norm]) {
                result.append(Token(original: tokens[index].original + " " + tokens[index + 1].original,
                                    norm: "\(value)\(NumberWords.ordinalSuffix(value))"))
                index += 2
                continue
            }
            if let value = NumberWords.ordinals[word], word != "second" {
                result.append(Token(original: tokens[index].original, norm: "\(value)\(NumberWords.ordinalSuffix(value))"))
                index += 1
                continue
            }
            // Cardinals.
            let startsNumber = NumberWords.isNumberWord(word) && word != "oh"
                || ((word == "a" || word == "an") && index + 1 < tokens.count && tokens[index + 1].norm == "hundred")
            if startsNumber {
                var end = index + 1
                while end < tokens.count {
                    let next = tokens[end].norm
                    if NumberWords.isNumberWord(next) && next != "oh" { end += 1; continue }
                    if next == "and", end + 1 < tokens.count, NumberWords.isNumberWord(tokens[end + 1].norm),
                       ["hundred", "thousand", "million"].contains(tokens[end - 1].norm) { end += 2; continue }
                    break
                }
                let words = tokens[index..<end].map(\.norm)
                if let value = NumberWords.cardinal(words), !(words.count == 1 && (word == "a" || word == "an")) {
                    let original = tokens[index..<end].map(\.original).joined(separator: " ")
                    result.append(Token(original: original, norm: String(value)))
                    index = end
                    continue
                }
            }
            result.append(tokens[index])
            index += 1
        }
        return result
    }
}
