import Foundation

/// The result of local, deterministic understanding.
public enum FastPathResult: Sendable, Hashable {
    /// A confident tool call.
    case call(name: String, arguments: JSONValue, confidence: Double)
    /// Aside can't do exactly that, but can offer an alternative ("…want a reminder instead?").
    case offer(prompt: String, name: String, arguments: JSONValue)
    /// A local reply that needs no tool.
    case reply(SpeechPlan)

    public var toolName: String? {
        switch self {
        case .call(let name, _, _), .offer(_, let name, _): return name
        case .reply: return nil
        }
    }

    public var confidence: Double {
        switch self {
        case .call(_, _, let confidence): return confidence
        case .offer, .reply: return 1
        }
    }
}

/// High-precision grammar for the requests people make most.
///
/// It runs in well under a millisecond, works offline, and never guesses: anything it
/// isn't sure about is left to the on-device or cloud model. Recall-style matches carry
/// lower confidence so the router can fall back when nothing is found.
public struct FastPathParser: Sendable {
    public init() {}

    static let leadingFillers: [[String]] = [
        ["hey", "aside"], ["ok", "aside"], ["okay", "aside"], ["aside"], ["hey"], ["okay"], ["ok"], ["so"], ["um"], ["uh"],
        ["please"], ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["can", "u"], ["i", "need", "you", "to"],
        ["i", "want", "you", "to"], ["i'd", "like", "you", "to"], ["go", "ahead", "and"], ["just"], ["quickly"], ["also"],
        ["and"], ["now"], ["alright"], ["all", "right"], ["actually"], ["hi"], ["yo"], ["let's"], ["lets"],
    ]

    /// Removes leading politeness/fillers and trailing "please"/"thanks".
    public static func core(_ utterance: Utterance) -> Utterance {
        var tokens = utterance.tokens
        var changed = true
        while changed {
            changed = false
            for filler in leadingFillers where tokens.count > filler.count {
                if Array(tokens.prefix(filler.count).map(\.norm)) == filler {
                    tokens.removeFirst(filler.count)
                    changed = true
                }
            }
        }
        while let last = tokens.last, ["please", "thanks", "thank", "you", "aside"].contains(last.norm), tokens.count > 1 {
            if last.norm == "you", tokens.count >= 2, tokens[tokens.count - 2].norm != "thank" { break }
            tokens.removeLast()
        }
        return Utterance(raw: tokens.map(\.original).joined(separator: " "), tokens: tokens)
    }

    public func parse(_ input: Utterance) -> FastPathResult? {
        let u = Self.core(input)
        guard !u.isEmpty else { return nil }
        // Order matters: more specific grammars first.
        let grammars: [(Utterance) -> FastPathResult?] = [
            parseReminder, parseTimer, parseAlarm, parseCalendar, parseMusic, parseWeather, parseTimeAndDate,
            parseMath, parseMessaging, parsePlaces, parseMemory, parsePreferences, parseHelp,
        ]
        for grammar in grammars {
            if let result = grammar(u) { return result }
        }
        return nil
    }

    // MARK: Helpers

    /// If the utterance starts with any of the phrases, returns the index after it.
    func after(_ u: Utterance, _ phrases: [[String]]) -> Int? {
        for phrase in phrases.sorted(by: { $0.count > $1.count }) where u.hasPrefix(phrase) {
            return phrase.count
        }
        return nil
    }

    func text(_ u: Utterance, _ range: Range<Int>, excluding: Set<Int> = []) -> String {
        u.original(range, excluding: excluding).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips connector words from both ends of a token range.
    func trimmedRange(_ u: Utterance, _ range: Range<Int>, excluding: Set<Int>, leading: Set<String>, trailing: Set<String>) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, excluding.contains(lower) || leading.contains(u.tokens[lower].norm) { lower += 1 }
        while upper > lower, excluding.contains(upper - 1) || trailing.contains(u.tokens[upper - 1].norm) { upper -= 1 }
        return lower..<upper
    }

    /// Original text of the temporal tokens (in order), e.g. "tomorrow at 9".
    func whenText(_ u: Utterance, _ consumed: Set<Int>) -> String? {
        guard !consumed.isEmpty else { return nil }
        let phrase = consumed.sorted().map { u.tokens[$0].original }.joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    /// Finds temporal tokens in a range without resolving them (resolution happens at execution).
    func temporalTokens(_ u: Utterance, range: Range<Int>, purpose: TemporalPurpose) -> Set<Int> {
        let probe = TemporalParser(calendar: Calendar(identifier: .gregorian), now: Date(timeIntervalSince1970: 1_800_000_000))
        return probe.parse(u, purpose: purpose, range: range)?.consumed ?? []
    }

    // MARK: Reminders

    func parseReminder(_ u: Utterance) -> FastPathResult? {
        let createPrefixes: [[String]] = [
            ["remind", "me"], ["set", "a", "reminder"], ["set", "reminder"], ["create", "a", "reminder"], ["add", "a", "reminder"],
            ["make", "a", "reminder"], ["new", "reminder"], ["reminder"], ["don't", "let", "me", "forget"], ["do", "not", "let", "me", "forget"],
            ["remember", "to"], ["i", "need", "a", "reminder"], ["give", "me", "a", "reminder"], ["put", "a", "reminder"],
        ]
        if let start = after(u, createPrefixes) {
            // "remember to X" keeps "to" out of the title.
            let range = start..<u.count
            let consumed = temporalTokens(u, range: range, purpose: .schedule)
            let leading: Set<String> = ["to", "about", "that", "for", "me", "of", "on", "in", "i", "need", "have", "should", "must", "gotta", "got", "the"]
            var titleRange = trimmedRange(u, range, excluding: consumed, leading: ["to", "about", "that", "for", "me", "of", "on", "in", "at", "by"], trailing: ["to", "on", "at", "in", "by", "for", "about", "that"])
            // "remind me that I need to call mom" → "call mom"
            while titleRange.lowerBound < titleRange.upperBound,
                  ["i", "need", "have", "should", "must", "gotta", "got"].contains(u.tokens[titleRange.lowerBound].norm) {
                titleRange = trimmedRange(u, (titleRange.lowerBound + 1)..<titleRange.upperBound, excluding: consumed, leading: leading, trailing: [])
            }
            let title = text(u, titleRange, excluding: consumed)
            var arguments: JSONValue = [:]
            if !title.isEmpty { arguments["title"] = .string(title) }
            if let when = whenText(u, consumed) { arguments["when"] = .string(when) }
            return .call(name: "create_reminder", arguments: arguments, confidence: title.isEmpty ? 0.8 : 0.96)
        }

        // "add milk to my reminders" / "add call mom to my to do list"
        if u.hasPrefix(["add"]), let listIndex = u.find(["to", "my"], from: 1),
           let next = u.tokens.dropFirst(listIndex + 2).first?.norm, ["reminders", "list", "to", "todo", "to-do", "todos"].contains(next) {
            let title = text(u, 1..<listIndex)
            guard !title.isEmpty else { return nil }
            return .call(name: "create_reminder", arguments: ["title": .string(title)], confidence: 0.92)
        }

        // Listing
        let listPhrases: [[String]] = [
            ["what", "are", "my", "reminders"], ["what's", "on", "my", "to", "do", "list"], ["what's", "on", "my", "todo", "list"],
            ["what", "reminders", "do", "i", "have"], ["show", "my", "reminders"], ["list", "my", "reminders"], ["read", "my", "reminders"],
            ["do", "i", "have", "any", "reminders"], ["what", "do", "i", "need", "to", "do"], ["what", "do", "i", "have", "to", "do"],
            ["what's", "on", "my", "list"], ["my", "reminders"], ["what", "should", "i", "do"], ["any", "reminders"],
        ]
        if let start = after(u, listPhrases) {
            let consumed = temporalTokens(u, range: start..<u.count, purpose: .query)
            var arguments: JSONValue = [:]
            if let when = whenText(u, consumed) { arguments["when"] = .string(when) }
            return .call(name: "list_reminders", arguments: arguments, confidence: 0.93)
        }

        // Completing: "mark buy milk as done", "check off buy milk", "complete the reminder to call mom"
        if u.hasPrefix(["mark"]), let doneIndex = u.norms.lastIndex(where: { ["done", "complete", "completed", "finished"].contains($0) }), doneIndex > 1 {
            var end = doneIndex
            if u.tokens[end - 1].norm == "as" { end -= 1 }
            let search = text(u, trimmedRange(u, 1..<end, excluding: [], leading: ["the", "reminder", "to", "about", "my"], trailing: []))
            guard !search.isEmpty else { return nil }
            return .call(name: "complete_reminder", arguments: ["search": .string(search)], confidence: 0.93)
        }
        if let start = after(u, [["check", "off"], ["complete", "the", "reminder"], ["complete", "my", "reminder"], ["cross", "off"]]) {
            let search = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["the", "reminder", "to", "about", "my"], trailing: ["off", "from", "my", "list"]))
            guard !search.isEmpty else { return nil }
            return .call(name: "complete_reminder", arguments: ["search": .string(search)], confidence: 0.9)
        }

        // Deleting
        if let start = after(u, [["delete", "the", "reminder"], ["delete", "my", "reminder"], ["remove", "the", "reminder"],
                                 ["cancel", "the", "reminder"], ["cancel", "my", "reminder"], ["delete", "reminder"], ["remove", "my", "reminder"]]) {
            let search = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["to", "about", "for", "that"], trailing: []))
            var arguments: JSONValue = [:]
            if !search.isEmpty { arguments["search"] = .string(search) }
            return .call(name: "delete_reminder", arguments: arguments, confidence: 0.9)
        }
        return nil
    }

    // MARK: Timers

    func parseTimer(_ u: Utterance) -> FastPathResult? {
        let norms = u.norms
        guard norms.contains(where: { $0 == "timer" || $0 == "timers" || $0 == "countdown" }) else { return nil }

        // Status
        if let _ = after(u, [["how", "much", "time", "is", "left"], ["how", "much", "time", "left"], ["how", "long", "is", "left"],
                              ["how's", "my", "timer"], ["how", "is", "my", "timer"], ["check", "my", "timer"], ["check", "the", "timer"],
                              ["what", "are", "my", "timers"], ["how", "long", "left", "on"], ["time", "left", "on"], ["list", "my", "timers"]]) {
            return .call(name: "list_timers", arguments: [:], confidence: 0.95)
        }
        // Cancel
        if let start = after(u, [["cancel"], ["stop"], ["delete"], ["clear"], ["remove"], ["end"], ["turn", "off"], ["dismiss"]]) {
            let all = norms.contains("timers") || norms.contains("all")
            let labelRange = trimmedRange(u, start..<u.count, excluding: [], leading: ["the", "my", "all", "a"], trailing: ["timer", "timers"])
            let label = text(u, labelRange)
            var arguments: JSONValue = ["all": .bool(all)]
            if !label.isEmpty, !all { arguments["label"] = .string(label) }
            return .call(name: "cancel_timer", arguments: arguments, confidence: 0.93)
        }
        // Start
        let startPrefixes: [[String]] = [["set", "a"], ["set", "an"], ["set"], ["start", "a"], ["start", "an"], ["start"], ["create", "a"],
                                         ["make", "a"], ["begin", "a"], ["put", "on", "a"], ["timer"], ["give", "me", "a"]]
        let start = after(u, startPrefixes) ?? 0
        guard let timerIndex = norms.firstIndex(where: { $0 == "timer" || $0 == "countdown" }) else { return nil }
        // Duration before "timer" ("10 minute timer") or after ("timer for 10 minutes").
        var duration: SpokenDuration?
        var durationRange: Range<Int>?
        var index = start
        while index < norms.count {
            if let (found, end) = DurationParser.parse(norms, at: index) {
                duration = found
                durationRange = index..<end
                break
            }
            index += 1
        }
        guard let duration, let durationRange, duration.isClockOnly || duration.days < 2 else {
            if start <= timerIndex {
                return .call(name: "start_timer", arguments: [:], confidence: 0.8)
            }
            return nil
        }
        var excluded = Set(durationRange)
        excluded.insert(timerIndex)
        let labelRange = trimmedRange(u, start..<u.count, excluding: excluded, leading: ["a", "an", "the", "for", "my", "called", "named"], trailing: ["for", "a", "an", "the", "timer", "please", "on"])
        var label = text(u, labelRange, excluding: excluded)
        label = label.split(separator: " ").filter { !["for", "a", "timer", "an"].contains($0.lowercased()) }.joined(separator: " ")
        var arguments: JSONValue = ["seconds": .number(duration.approximateSeconds), "duration": .string(text(u, durationRange))]
        if !label.isEmpty { arguments["label"] = .string(label) }
        return .call(name: "start_timer", arguments: arguments, confidence: 0.97)
    }

    // MARK: Alarms (honest alternative)

    func parseAlarm(_ u: Utterance) -> FastPathResult? {
        guard let start = after(u, [["wake", "me", "up"], ["wake", "me"], ["set", "an", "alarm"], ["set", "alarm"], ["set", "my", "alarm"], ["alarm", "for"]]) else { return nil }
        let consumed = temporalTokens(u, range: start..<u.count, purpose: .schedule)
        let when = whenText(u, consumed) ?? "tomorrow morning"
        return .offer(prompt: "I can't set wake-up alarms yet. Want a reminder \(when) instead?",
                      name: "create_reminder", arguments: ["title": "Wake up", "when": .string(when)])
    }

    // MARK: Calendar

    func parseCalendar(_ u: Utterance) -> FastPathResult? {
        let queryPrefixes: [[String]] = [
            ["what's", "on", "my", "calendar"], ["what", "is", "on", "my", "calendar"], ["what's", "on", "my", "schedule"],
            ["what", "is", "on", "my", "schedule"], ["what's", "my", "schedule"], ["what", "is", "my", "schedule"], ["what's", "my", "day", "look", "like"],
            ["what", "does", "my", "day", "look", "like"], ["what", "does", "my", "schedule", "look", "like"], ["what's", "my", "calendar"],
            ["what", "do", "i", "have"], ["what", "have", "i", "got"], ["what's", "happening"], ["do", "i", "have", "anything"],
            ["do", "i", "have", "any", "meetings"], ["do", "i", "have", "meetings"], ["any", "meetings"], ["what", "meetings", "do", "i", "have"],
            ["read", "my", "calendar"], ["check", "my", "calendar"], ["show", "my", "calendar"], ["my", "schedule"], ["my", "calendar"],
            ["what's", "on"], ["what", "is", "on"], ["how", "busy", "am", "i"], ["how's", "my", "day"], ["what's", "going", "on"],
        ]
        if let start = after(u, queryPrefixes) {
            let rest = Array(u.norms[start...])
            let consumed = temporalTokens(u, range: start..<u.count, purpose: .query)
            // Bare "what's on…" / "what's happening…" only counts with a time ("what's on tomorrow"), not "what's on TV".
            let bare: [[String]] = [["what's", "on"], ["what", "is", "on"], ["what's", "going", "on"], ["what's", "happening"], ["what", "do", "i", "have"], ["what", "have", "i", "got"]]
            if bare.contains(where: { $0.count == start && u.hasPrefix($0) }) {
                guard !consumed.isEmpty, consumed.count >= rest.count - 1 else { return nil }
            }
            var arguments: JSONValue = [:]
            if let when = whenText(u, consumed) { arguments["when"] = .string(when) }
            if rest.contains("meetings") || rest.contains("meeting") { arguments["search"] = "" }
            return .call(name: "get_schedule", arguments: arguments, confidence: 0.94)
        }
        // Free/busy
        if let start = after(u, [["am", "i", "free"], ["am", "i", "busy"], ["am", "i", "available"], ["do", "i", "have", "time"]]) {
            let consumed = temporalTokens(u, range: start..<u.count, purpose: .query)
            var arguments: JSONValue = ["availability": true]
            if let when = whenText(u, consumed) { arguments["when"] = .string(when) }
            return .call(name: "get_schedule", arguments: arguments, confidence: 0.92)
        }
        // Next event
        if let start = after(u, [["what's", "next"], ["what", "is", "next"], ["what's", "my", "next"], ["what", "is", "my", "next"],
                                 ["when's", "my", "next"], ["when", "is", "my", "next"], ["when", "do", "i", "have", "my", "next"],
                                 ["where's", "my", "next"], ["where", "is", "my", "next"]]) {
            let rest = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["on", "my", "the"], trailing: ["calendar", "schedule", "on", "my", "today"]))
            var arguments: JSONValue = ["next": true]
            let generic: Set<String> = ["", "meeting", "event", "appointment", "thing", "call"]
            if !generic.contains(rest.lowercased()) { arguments["search"] = .string(rest) }
            return .call(name: "get_schedule", arguments: arguments, confidence: 0.92)
        }
        // Create
        let createPrefixes: [[String]] = [
            ["add", "an", "event"], ["add", "a", "meeting"], ["create", "an", "event"], ["create", "a", "meeting"], ["create", "event"],
            ["schedule", "a", "meeting"], ["schedule", "an", "event"], ["schedule", "a"], ["schedule"], ["put"], ["add"], ["book", "a"], ["block", "out"], ["block"],
            ["new", "event"], ["make", "an", "event"], ["set", "up", "a", "meeting"], ["set", "up"],
        ]
        if let start = after(u, createPrefixes) {
            let norms = u.norms
            let mentionsCalendar = norms.contains("calendar") || u.hasPrefix(["schedule"]) || u.hasPrefix(["create"]) || u.hasPrefix(["block"])
                || norms.contains("event") || norms.contains("meeting") || u.hasPrefix(["book"]) || u.hasPrefix(["set", "up"]) || u.hasPrefix(["new", "event"]) || u.hasPrefix(["make", "an", "event"])
            guard mentionsCalendar else { return nil }
            var range = start..<u.count
            // Remove "on my calendar" / "to my calendar"
            var excluded = Set<Int>()
            if let calendarIndex = norms.firstIndex(of: "calendar") {
                excluded.insert(calendarIndex)
                if calendarIndex > 0, ["my", "the"].contains(norms[calendarIndex - 1]) { excluded.insert(calendarIndex - 1) }
                if calendarIndex > 1, ["on", "to", "in"].contains(norms[calendarIndex - 2]) { excluded.insert(calendarIndex - 2) }
            }
            let consumed = temporalTokens(u, range: range, purpose: .schedule)
            excluded.formUnion(consumed)
            // Duration "for an hour"
            var durationMinutes: Double?
            var index = start
            while index < norms.count {
                if norms[index] == "for", let (duration, end) = DurationParser.parse(norms, at: index + 1), duration.isClockOnly {
                    durationMinutes = duration.seconds / 60
                    excluded.formUnion(index..<end)
                    break
                }
                index += 1
            }
            range = trimmedRange(u, range, excluding: excluded, leading: ["an", "a", "event", "meeting", "called", "for", "named", "the", "time"], trailing: ["on", "at", "for", "to", "in"])
            let title = text(u, range, excluding: excluded)
            guard !consumed.isEmpty else { return nil }
            var arguments: JSONValue = ["when": .string(whenText(u, consumed) ?? "")]
            if !title.isEmpty { arguments["title"] = .string(title) }
            if let durationMinutes { arguments["duration_minutes"] = .number(durationMinutes) }
            return .call(name: "create_event", arguments: arguments, confidence: title.isEmpty ? 0.75 : 0.9)
        }
        return nil
    }

    // MARK: Music

    func parseMusic(_ u: Utterance) -> FastPathResult? {
        let norms = u.norms
        // Transport controls
        let text = norms.joined(separator: " ")
        let controls: [(Set<String>, String)] = [
            (["pause", "pause music", "pause the music", "pause it", "pause the song", "pause playback", "stop the music", "stop music", "stop playing", "stop the song", "music off"], "pause"),
            (["resume", "resume music", "resume the music", "unpause", "keep playing", "continue playing", "resume playback", "play again", "start the music again"], "resume"),
            (["skip", "skip this", "skip it", "skip this song", "skip song", "skip track", "next song", "next track", "play the next song", "skip the song", "next"], "next"),
            (["previous song", "previous track", "last song", "go back a song", "play the previous song", "back one song"], "previous"),
        ]
        for (phrases, action) in controls where phrases.contains(text) {
            return .call(name: "control_playback", arguments: ["action": .string(action)], confidence: 0.95)
        }
        if ["what's playing", "what is playing", "what song is this", "what's this song", "what is this song", "who is this", "who's singing", "what am i listening to", "who sings this"].contains(text) {
            return .call(name: "now_playing", arguments: [:], confidence: 0.85)
        }

        guard let start = after(u, [["play"], ["put", "on"], ["shuffle"], ["listen", "to"], ["i", "want", "to", "listen", "to"], ["start", "playing"]]) else { return nil }
        var end = u.count
        var provider: String?
        // "... on spotify" / "... in apple music" / "... using spotify"
        for (phrase, name) in [(["spotify"], "spotify"), (["apple", "music"], "apple_music"), (["itunes"], "apple_music"), (["music", "app"], "apple_music")] {
            if end >= phrase.count + 1, Array(norms[(end - phrase.count)..<end]) == phrase,
               ["on", "in", "using", "with", "from", "via"].contains(norms[end - phrase.count - 1]) {
                provider = name
                end -= phrase.count + 1
                break
            }
        }
        var kind = "any"
        var queryStart = start
        if let next = norms.dropFirst(queryStart).first {
            switch next {
            case "the" where norms.count > queryStart + 1 && ["song", "album", "playlist", "artist", "track"].contains(norms[queryStart + 1]):
                kind = norms[queryStart + 1] == "track" ? "song" : norms[queryStart + 1]
                queryStart += 2
            case "song", "album", "playlist", "artist", "track":
                kind = next == "track" ? "song" : next
                queryStart += 1
            case "my" where norms.count > queryStart + 1:
                if norms[queryStart + 1] == "playlist" { kind = "playlist"; queryStart += 2 }
                else if norms.dropFirst(queryStart).contains("playlist") { kind = "playlist" }
            case "some" :
                queryStart += 1
                kind = "genre"
            default:
                break
            }
        }
        var query = self.text(u, queryStart..<end)
        if ["music", "something", "some music", "anything", "a song", "songs", "tunes"].contains(query.lowercased()) || query.isEmpty {
            query = ""
            kind = "any"
        }
        // "play" alone is resume.
        if query.isEmpty && provider == nil && u.count == start {
            return .call(name: "control_playback", arguments: ["action": "resume"], confidence: 0.85)
        }
        var arguments: JSONValue = ["query": .string(query), "kind": .string(kind)]
        if let provider { arguments["provider"] = .string(provider) }
        if u.hasPrefix(["shuffle"]) { arguments["shuffle"] = true }
        return .call(name: "play_music", arguments: arguments, confidence: 0.93)
    }

    // MARK: Weather

    func parseWeather(_ u: Utterance) -> FastPathResult? {
        let norms = u.norms
        let weatherWords: Set<String> = ["weather", "forecast", "rain", "raining", "snow", "snowing", "umbrella", "temperature", "jacket", "coat",
                                         "hot", "cold", "warm", "sunny", "windy", "humid", "storm", "degrees", "outside"]
        guard norms.contains(where: weatherWords.contains) else { return nil }
        let questionStarts: [[String]] = [["what's"], ["what", "is"], ["how's"], ["how", "is"], ["is", "it"], ["will", "it"], ["is", "there"], ["do", "i", "need"],
                                          ["should", "i", "bring"], ["should", "i", "take"], ["how", "hot"], ["how", "cold"], ["how", "warm"], ["weather"],
                                          ["what", "will", "the", "weather"], ["what's", "the", "weather"], ["forecast"], ["tell", "me", "the", "weather"],
                                          ["check", "the", "weather"], ["give", "me", "the", "weather"], ["is", "it", "going", "to"], ["what", "temperature"],
                                          ["what's", "the", "temperature"], ["how", "many", "degrees"]]
        guard let start = after(u, questionStarts) else { return nil }
        // Don't steal "what's the weather like in my calendar" style compounds or "is it cold in here" (indoor).
        if norms.contains("here") && !norms.contains("weather") { return nil }
        let consumed = temporalTokens(u, range: start..<u.count, purpose: .query)
        var arguments: JSONValue = [:]
        if let when = whenText(u, consumed) { arguments["when"] = .string(when) }
        // Place: tokens after "in"/"for"/"at" that aren't temporal.
        func startsPlace(_ index: Int) -> Bool {
            guard index >= start, index + 1 < norms.count, !consumed.contains(index), !consumed.contains(index + 1) else { return false }
            let word = norms[index]
            let next = norms[index + 1]
            if ["in", "for", "at"].contains(word) && !["the", "a", "my"].contains(next) { return true }
            if word == "in", next == "the", index + 2 < norms.count, !consumed.contains(index + 2) {
                return !["morning", "afternoon", "evening"].contains(norms[index + 2])
            }
            return false
        }
        if let inIndex = norms.indices.first(where: startsPlace) {
            let placeRange = trimmedRange(u, (inIndex + 1)..<u.count, excluding: consumed, leading: ["the"], trailing: ["today", "tomorrow", "right", "now", "like", "outside"])
            let place = text(u, placeRange, excluding: consumed)
            if !place.isEmpty, !["here", "outside", "now"].contains(place.lowercased()) { arguments["place"] = .string(place) }
        }
        if norms.contains("umbrella") || norms.contains("rain") || norms.contains("raining") { arguments["focus"] = "precipitation" }
        if norms.contains("jacket") || norms.contains("coat") || norms.contains("cold") || norms.contains("hot") || norms.contains("warm") { arguments["focus"] = "temperature" }
        return .call(name: "get_weather", arguments: arguments, confidence: 0.92)
    }

    // MARK: Time & date

    func parseTimeAndDate(_ u: Utterance) -> FastPathResult? {
        if let start = after(u, [["what", "time", "is", "it"], ["what's", "the", "time"], ["what", "is", "the", "time"], ["what", "time's", "it"],
                                 ["time", "in"], ["current", "time"], ["tell", "me", "the", "time"], ["do", "you", "know", "what", "time", "it", "is"]]) {
            var place: String?
            var index = u.hasPrefix(["time", "in"]) ? start - 1 : start
            if index < u.count, ["in", "at", "over", "for"].contains(u.tokens[index].norm) { index += 1 }
            if index < u.count {
                let placeText = text(u, trimmedRange(u, index..<u.count, excluding: [], leading: ["in", "the", "at"], trailing: ["right", "now"]))
                if !placeText.isEmpty, !["now", "right now"].contains(placeText.lowercased()) { place = placeText }
            }
            var arguments: JSONValue = ["question": "time"]
            if let place { arguments["place"] = .string(place) }
            return .call(name: "get_time", arguments: arguments, confidence: 0.97)
        }
        if let start = after(u, [["what's", "the", "date"], ["what", "is", "the", "date"], ["what's", "today's", "date"], ["what", "is", "today's", "date"],
                                 ["what", "day", "is", "it"], ["what", "day", "is"], ["what", "day", "of", "the", "week", "is"], ["what's", "the", "day"],
                                 ["what", "date", "is"], ["today's", "date"]]) {
            let consumed = temporalTokens(u, range: start..<u.count, purpose: .query)
            var arguments: JSONValue = ["question": "date"]
            if let when = whenText(u, consumed) { arguments["when"] = .string(when) }
            return .call(name: "get_time", arguments: arguments, confidence: 0.95)
        }
        if let start = after(u, [["how", "many", "days", "until"], ["how", "many", "days", "till"], ["how", "many", "days", "to"], ["how", "long", "until"], ["how", "long", "till"],
                                 ["how", "many", "weeks", "until"], ["how", "many", "days", "left", "until"]]) {
            let consumed = temporalTokens(u, range: start..<u.count, purpose: .query)
            let target = whenText(u, consumed) ?? text(u, start..<u.count)
            guard !target.isEmpty else { return nil }
            return .call(name: "get_time", arguments: ["question": "until", "when": .string(target)], confidence: consumed.isEmpty ? 0.6 : 0.93)
        }
        return nil
    }

    // MARK: Math

    func parseMath(_ u: Utterance) -> FastPathResult? {
        let norms = u.norms
        let start = after(u, [["what's"], ["what", "is"], ["calculate"], ["how", "much", "is"], ["compute"], ["what", "are"]]) ?? 0
        let body = Array(norms[start...])
        guard !body.isEmpty else { return nil }
        let hasNumber = body.contains { NumberWords.numeric($0) != nil }
        let operators: Set<String> = ["plus", "minus", "times", "multiplied", "divided", "over", "+", "-", "*", "x", "/", "percent", "%", "squared", "cubed", "root", "of", "mod"]
        let conversion = body.contains("in") || body.contains("to") || body.contains("into")
        guard hasNumber else { return nil }
        let hasOperator = body.contains { operators.contains($0) } || body.contains { $0.hasSuffix("%") }
        if hasOperator || (conversion && UnitConverter.mentionsUnits(body)) {
            let expression = text(u, start..<u.count)
            // Make sure the calculator can parse it; otherwise let a model handle it.
            guard Calculator.evaluate(expression) != nil || UnitConverter.convert(expression) != nil else { return nil }
            return .call(name: "calculate", arguments: ["expression": .string(expression)], confidence: 0.95)
        }
        return nil
    }

    // MARK: Messaging & calls

    func parseMessaging(_ u: Utterance) -> FastPathResult? {
        let norms = u.norms
        // "call me X" is a preference, not a phone call.
        if u.hasPrefix(["call", "me"]) { return nil }
        if let start = after(u, [["call"], ["phone"], ["dial"], ["ring"], ["facetime"], ["give", "a", "call", "to"]]), start < u.count {
            let name = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["my"], trailing: ["now", "please", "back", "on", "mobile", "cell", "phone", "her", "his"]))
            guard !name.isEmpty, name.split(separator: " ").count <= 4 else { return nil }
            var arguments: JSONValue = ["recipient": .string(name)]
            if u.hasPrefix(["facetime"]) { arguments["facetime"] = true }
            return .call(name: "call_contact", arguments: arguments, confidence: 0.9)
        }

        let verbs: [[String]] = [["send", "a", "text", "to"], ["send", "a", "message", "to"], ["send", "text", "to"], ["send", "message", "to"],
                                 ["text"], ["message"], ["send", "a", "text"], ["send", "a", "message"], ["tell"], ["send"], ["imessage"]]
        guard let start = after(u, verbs), start < u.count else { return nil }
        if u.hasPrefix(["tell", "me"]) || u.hasPrefix(["send", "me"]) { return nil }
        if u.hasPrefix(["send"]) && !norms.contains("text") && !norms.contains("message") && !norms.contains("saying") { return nil }
        // Body markers
        let markers: [[String]] = [["saying"], ["that", "says"], ["and", "say"], ["and", "tell", "them"], ["to", "say"], ["and", "ask", "if"], ["asking"], ["that"]]
        var recipientEnd: Int?
        var bodyStart: Int?
        for marker in markers {
            if let index = u.find(marker, from: start + 1) {
                recipientEnd = index
                bodyStart = index + marker.count
                if marker == ["and", "ask", "if"] || marker == ["asking"] { bodyStart = index + marker.count }
                break
            }
        }
        if recipientEnd == nil {
            // No marker: recipient is the leading run of capitalized words (names), or a relation ("mom").
            var index = start
            if index < u.count, u.tokens[index].norm == "my" { index += 1 }
            let relations: Set<String> = ["mom", "mum", "dad", "mother", "father", "wife", "husband", "partner", "boyfriend", "girlfriend", "brother", "sister", "boss", "son", "daughter"]
            if index < u.count, relations.contains(u.tokens[index].norm) {
                recipientEnd = index + 1
            } else {
                var end = index
                let pronouns: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "im"]
                while end < u.count, end - index < 3, let first = u.tokens[end].original.first, first.isUppercase, !pronouns.contains(u.tokens[end].norm) {
                    end += 1
                }
                if end == index, index < u.count { end = index + 1 }
                recipientEnd = end
            }
            bodyStart = recipientEnd
        }
        guard let recipientEnd, let bodyStart, recipientEnd > start else { return nil }
        let recipient = text(u, trimmedRange(u, start..<recipientEnd, excluding: [], leading: ["to", "my"], trailing: ["a", "and"]))
        let body = text(u, bodyStart..<u.count)
        guard !recipient.isEmpty else { return nil }
        var arguments: JSONValue = ["recipient": .string(recipient)]
        if !body.isEmpty { arguments["body"] = .string(body) }
        return .call(name: "send_message", arguments: arguments, confidence: body.isEmpty ? 0.8 : 0.9)
    }

    // MARK: Places

    func parsePlaces(_ u: Utterance) -> FastPathResult? {
        if let start = after(u, [["directions", "to"], ["navigate", "to"], ["take", "me", "to"], ["get", "me", "directions", "to"], ["give", "me", "directions", "to"],
                                 ["how", "do", "i", "get", "to"], ["route", "to"], ["drive", "to"], ["walk", "to"]]) {
            let destination = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["the"], trailing: []))
            guard !destination.isEmpty else { return nil }
            var arguments: JSONValue = ["destination": .string(destination)]
            if u.hasPrefix(["walk", "to"]) { arguments["mode"] = "walking" }
            return .call(name: "open_directions", arguments: arguments, confidence: 0.92)
        }
        if let start = after(u, [["how", "long", "will", "it", "take", "to", "get", "to"], ["how", "long", "does", "it", "take", "to", "get", "to"],
                                 ["how", "long", "to", "get", "to"], ["how", "far", "is"], ["how", "far", "away", "is"], ["how", "long", "is", "the", "drive", "to"],
                                 ["how", "long", "would", "it", "take", "to", "get", "to"], ["eta", "to"], ["how", "far", "to"]]) {
            let destination = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["the"], trailing: ["from", "here", "away"]))
            guard !destination.isEmpty else { return nil }
            var arguments: JSONValue = ["destination": .string(destination)]
            if u.norms.contains("walk") || u.norms.contains("walking") { arguments["mode"] = "walking" }
            return .call(name: "get_travel_time", arguments: arguments, confidence: 0.9)
        }
        if let start = after(u, [["find", "a"], ["find", "an"], ["find", "me", "a"], ["find", "the", "nearest"], ["where's", "the", "nearest"], ["where", "is", "the", "nearest"],
                                 ["is", "there", "a"], ["are", "there", "any"], ["nearest"], ["closest"], ["where's", "the", "closest"], ["where", "is", "the", "closest"],
                                 ["find", "nearby"], ["search", "for", "a"]]) {
            let norms = u.norms
            let nearby = norms.contains("near") || norms.contains("nearby") || norms.contains("nearest") || norms.contains("closest") || norms.contains("around")
            guard nearby || u.hasPrefix(["find"]) else { return nil }
            let query = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["the", "a", "an", "good"], trailing: ["near", "me", "nearby", "around", "here", "close", "by", "to"]))
            guard !query.isEmpty, !["reminder", "note", "song", "timer"].contains(query.lowercased()) else { return nil }
            return .call(name: "find_places", arguments: ["query": .string(query)], confidence: 0.88)
        }
        return nil
    }

    // MARK: Memory & notes

    func parseMemory(_ u: Utterance) -> FastPathResult? {
        let norms = u.norms
        if let start = after(u, [["take", "a", "note"], ["make", "a", "note"], ["note", "that"], ["note"], ["write", "down"], ["jot", "down"],
                                 ["add", "a", "note"], ["save", "a", "note"], ["new", "note"], ["note", "to", "self"], ["make", "note"]]) {
            let content = text(u, trimmedRange(u, start..<u.count, excluding: [], leading: ["that", "of", "saying", "to", "self"], trailing: []))
            var arguments: JSONValue = ["kind": "note", "user_asked": true]
            if !content.isEmpty { arguments["text"] = .string(content) }
            return .call(name: "save_note", arguments: arguments, confidence: content.isEmpty ? 0.8 : 0.95)
        }
        if u.hasPrefix(["remember", "that"]) || (u.hasPrefix(["remember"]) && !u.hasPrefix(["remember", "to"]) && u.count > 2 && !u.hasPrefix(["remember", "when"])) {
            let start = u.hasPrefix(["remember", "that"]) ? 2 : 1
            let content = text(u, start..<u.count)
            guard !content.isEmpty else { return nil }
            let lower = content.lowercased()
            let kind = ["i prefer", "i like", "i love", "i hate", "i don't like", "my favorite", "i always", "i never", "i'm allergic", "i am allergic", "i'm vegetarian", "i'm vegan"]
                .contains { lower.hasPrefix($0) } ? "preference" : "fact"
            return .call(name: "save_note", arguments: ["kind": .string(kind), "text": .string(content), "user_asked": true], confidence: 0.94)
        }
        if u.hasPrefix(["i", "parked"]) || u.hasPrefix(["i'm", "parked"]) || u.hasPrefix(["i", "left", "my"]) || u.hasPrefix(["i", "put", "my"]) {
            return .call(name: "save_note", arguments: ["kind": "note", "text": .string(text(u, 0..<u.count)), "user_asked": true], confidence: 0.85)
        }
        if let start = after(u, [["forget", "everything"], ["forget", "all"], ["delete", "everything", "you", "know"], ["erase", "everything"], ["delete", "all", "my", "notes"]]) {
            _ = start
            return .call(name: "forget", arguments: ["all": true], confidence: 0.95)
        }
        if let start = after(u, [["forget", "that"], ["forget", "about"], ["forget", "the"], ["forget", "my"], ["forget"], ["delete", "the", "note", "about"], ["delete", "the", "note"],
                                 ["remove", "the", "note", "about"], ["stop", "remembering"], ["don't", "remember"]]), start < u.count {
            let query = text(u, start..<u.count)
            guard !query.isEmpty, !["it", "that"].contains(query.lowercased()) else { return .call(name: "forget", arguments: ["last": true], confidence: 0.85) }
            return .call(name: "forget", arguments: ["query": .string(query)], confidence: 0.9)
        }
        if let start = after(u, [["what", "do", "you", "know", "about"], ["what", "do", "you", "remember", "about"], ["what", "did", "i", "say", "about"],
                                 ["what", "did", "i", "tell", "you", "about"], ["what", "notes", "do", "i", "have", "about"], ["do", "you", "remember"],
                                 ["what", "did", "i", "note", "about"], ["find", "my", "note", "about"], ["read", "my", "notes", "about"]]) {
            let query = text(u, start..<u.count)
            if ["me", "myself"].contains(query.lowercased()) {
                return .call(name: "recall", arguments: ["query": "", "about_user": true], confidence: 0.95)
            }
            return .call(name: "recall", arguments: ["query": .string(query)], confidence: 0.9)
        }
        if ["what do you know about me", "what do you remember about me", "what have you remembered", "what do you remember", "read my notes", "what are my notes", "show my notes"].contains(norms.joined(separator: " ")) {
            return .call(name: "recall", arguments: ["query": "", "about_user": true], confidence: 0.95)
        }
        if let start = after(u, [["where", "did", "i", "park"], ["where's", "my", "car"], ["where", "is", "my", "car"], ["where", "did", "i", "leave", "my"],
                                 ["where", "did", "i", "put", "my"]]) {
            let tail = text(u, start..<u.count)
            return .call(name: "recall", arguments: ["query": .string("parked " + tail + " " + u.raw), "fallthrough": true], confidence: 0.7)
        }
        // "what's my gate code", "what's my wife's name" — answerable only if remembered.
        // Personal ("my") questions try memory first; if nothing is saved they fall through to a model.
        if let start = after(u, [["what's", "my"], ["what", "is", "my"], ["what", "was", "my"], ["when", "is", "my"], ["when's", "my"], ["who", "is", "my"], ["who's", "my"]]) {
            let subject = text(u, start..<u.count)
            guard !subject.isEmpty else { return nil }
            return .call(name: "recall", arguments: ["query": .string(subject), "fallthrough": true], confidence: 0.8)
        }
        return nil
    }

    // MARK: Preferences

    func parsePreferences(_ u: Utterance) -> FastPathResult? {
        if let start = after(u, [["call", "me"], ["my", "name", "is"]]), start < u.count {
            let name = text(u, start..<u.count)
            guard !name.isEmpty, name.split(separator: " ").count <= 3 else { return nil }
            return .call(name: "set_preference", arguments: ["setting": "preferred_name", "value": .string(name)], confidence: 0.9)
        }
        let text = u.norms.joined(separator: " ")
        let verbosity: [(Set<String>, String)] = [
            (["talk less", "be brief", "be more brief", "shorter answers", "keep it short", "less talking", "be more concise", "be concise", "say less"], "minimal"),
            (["talk more", "more detail", "give me more detail", "longer answers", "be more detailed", "explain more"], "detailed"),
            (["normal answers", "talk normally", "regular answers"], "balanced"),
        ]
        for (phrases, value) in verbosity where phrases.contains(text) {
            return .call(name: "set_preference", arguments: ["setting": "verbosity", "value": .string(value)], confidence: 0.92)
        }
        for (phrase, value) in [("use spotify", "spotify"), ("use apple music", "apple_music"), ("use spotify for music", "spotify"),
                                ("use apple music for music", "apple_music"), ("use spotify by default", "spotify"), ("use apple music by default", "apple_music")] where text == phrase {
            return .call(name: "set_preference", arguments: ["setting": "music_provider", "value": .string(value)], confidence: 0.92)
        }
        return nil
    }

    // MARK: Help

    func parseHelp(_ u: Utterance) -> FastPathResult? {
        let text = u.norms.joined(separator: " ")
        guard ["what can you do", "what can you help with", "what can i ask you", "help", "what do you do", "how do you work", "what are you"].contains(text) else { return nil }
        if text == "what are you" {
            return .reply(SpeechPlan(minimal: "I'm Aside, an AI assistant.",
                                     balanced: "I'm Aside — an AI assistant that lives on your devices and takes care of everyday things.",
                                     detailed: "I'm Aside, an AI assistant. I'm not a person — I'm software that can handle reminders, your schedule, timers, music, weather, directions, messages and notes, and answer questions."))
        }
        return .reply(SpeechPlan(
            minimal: "Reminders, your schedule, timers, music, weather, directions, messages, notes and questions.",
            balanced: "I can set reminders and timers, check and add to your calendar, play music, get the weather and directions, start messages and calls, keep notes, and answer questions. Just say what you need.",
            detailed: "I can set reminders and timers, tell you what's on your calendar and add events, play music on Apple Music or Spotify, check the weather, find places and travel times, start messages and calls for you to send, remember notes and preferences, and answer questions. Anything that affects other people, I'll check with you first."))
    }
}
