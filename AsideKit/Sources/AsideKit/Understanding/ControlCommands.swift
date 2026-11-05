import Foundation

/// Utterances that steer the agent itself rather than asking for a task.
///
/// These are recognized locally, instantly, in every state — including while Aside is
/// speaking — so "stop" always works, even offline.
public enum ControlCommand: Sendable, Hashable {
    /// Stop talking / stop what you're doing. No further response.
    case stop
    /// Cancel the pending or in-flight action ("cancel that"). Undoes the last action if it already completed recently.
    case cancel
    /// Drop everything quietly ("never mind", "forget it").
    case dismiss
    /// Pause speech and keep listening ("wait", "hold on").
    case hold
    /// Resume after a hold ("go on", "continue").
    case resume
    /// Repeat the last response.
    case repeatLast
    /// Undo the most recent action.
    case undo
    /// "What are you doing?"
    case status
    /// "What did you just do?"
    case explainLast
    /// End of conversation ("that's all", "thanks").
    case done
    /// Speak louder / quieter / faster / slower.
    case adjustSpeech(SpeechAdjustment)
    /// Stop speaking aloud ("be quiet", "be discreet") / allow speaking again.
    case setDiscreet(Bool)
}

public enum SpeechAdjustment: Sendable, Hashable {
    case louder, quieter, faster, slower
}

public enum ControlCommandParser {
    /// Recognizes a control command when it is the whole utterance (with politeness and fillers allowed).
    public static func parse(_ utterance: Utterance) -> ControlCommand? {
        var words = utterance.norms
        let politeness: Set<String> = ["please", "okay", "ok", "hey", "aside", "oh", "uh", "actually", "just", "so", "now", "right"]
        while let first = words.first, politeness.contains(first) { words.removeFirst() }
        while let last = words.last, politeness.contains(last) { words.removeLast() }
        guard !words.isEmpty, words.count <= 7 else { return nil }
        let text = words.joined(separator: " ")

        if ["stop", "stop it", "stop talking", "shush", "shh", "quiet", "be quiet", "enough", "that's enough", "stop stop", "silence", "shut up"].contains(text) {
            return text == "be quiet" ? .setDiscreet(true) : .stop
        }
        if ["cancel", "cancel that", "cancel it", "don't do that", "do not do that", "scratch that", "cancel the last one", "no cancel", "abort"].contains(text) {
            return .cancel
        }
        if ["never mind", "nevermind", "forget it", "forget about it", "no never mind", "never mind that", "ignore that", "nothing", "no nothing"].contains(text) {
            return .dismiss
        }
        if ["wait", "hold on", "wait a second", "wait a sec", "hang on", "one second", "one sec", "wait wait", "hold on a second", "pause"].contains(text) {
            return .hold
        }
        if ["go on", "continue", "keep going", "go ahead and continue", "carry on", "resume", "go ahead"].contains(text) {
            return .resume
        }
        if ["repeat", "repeat that", "say that again", "what did you say", "come again", "pardon", "sorry what", "what", "say again", "can you repeat that"].contains(text) {
            return .repeatLast
        }
        if ["undo", "undo that", "undo it", "take that back", "revert that", "undo the last thing"].contains(text) {
            return .undo
        }
        if ["what are you doing", "what are you working on", "are you still there", "are you there", "what's happening", "what is happening", "what's going on", "status"].contains(text) {
            return .status
        }
        if ["what did you do", "what did you just do", "what did you just say", "what just happened", "what did you change"].contains(text) {
            return text == "what did you just say" ? .repeatLast : .explainLast
        }
        if ["that's all", "that's it", "that is all", "thanks", "thank you", "thanks that's all", "thank you that's all", "all done", "i'm done", "goodbye", "bye", "done", "perfect thanks", "great thanks", "cool thanks"].contains(text) {
            return .done
        }
        if ["louder", "speak up", "talk louder", "speak louder", "turn it up", "volume up"].contains(text) { return .adjustSpeech(.louder) }
        if ["quieter", "softer", "speak softer", "talk quieter", "turn it down", "volume down", "lower your voice"].contains(text) { return .adjustSpeech(.quieter) }
        if ["faster", "speak faster", "talk faster", "speed up"].contains(text) { return .adjustSpeech(.faster) }
        if ["slower", "speak slower", "talk slower", "slow down", "speak more slowly"].contains(text) { return .adjustSpeech(.slower) }
        if ["be discreet", "stop talking out loud", "don't talk out loud", "silent mode", "text only", "go silent", "don't speak"].contains(text) {
            return .setDiscreet(true)
        }
        if ["you can talk again", "talk out loud", "speak out loud", "you can speak again", "voice on", "talk to me"].contains(text) {
            return .setDiscreet(false)
        }
        return nil
    }

    /// Words that indicate an interruption even inside longer speech ("stop, I meant tomorrow").
    public static func startsWithInterruption(_ utterance: Utterance) -> Bool {
        guard let first = utterance.norms.first else { return false }
        return ["stop", "wait", "no", "cancel", "actually", "hold"].contains(first)
    }
}

/// Parses answers to Aside's own questions: yes/no, choices and slot values.
public enum AnswerParser {
    public enum YesNo: Sendable, Hashable { case yes, no }

    public static func yesNo(_ utterance: Utterance) -> YesNo? {
        let words = utterance.norms.filter { !["please", "okay", "ok", "oh", "um", "actually", "aside"].contains($0) }
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let text = words.joined(separator: " ")
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "correct", "right", "that's right", "do it", "go ahead", "please do",
                                "confirm", "send it", "send", "yes please", "yes send it", "sounds good", "ok do it", "affirmative",
                                "that's correct", "yes do it", "absolutely", "definitely", "go for it", "save it", "yes save it", "remember it", "yes remember it"]
        let no: Set<String> = ["no", "nope", "nah", "don't", "do not", "no thanks", "no thank you", "cancel", "don't send it",
                               "don't do it", "not now", "wrong", "that's wrong", "negative", "no don't", "never mind", "stop"]
        if yes.contains(text) { return .yes }
        if no.contains(text) { return .no }
        if let first = words.first, words.count <= 3 {
            if ["yes", "yeah", "yep", "sure"].contains(first) { return .yes }
            if ["no", "nope", "nah"].contains(first) && words.count == 1 { return .no }
        }
        return nil
    }

    /// Picks an option by ordinal ("the second one"), position ("the last one") or by name.
    public static func choice(_ utterance: Utterance, options: [String]) -> Int? {
        guard !options.isEmpty else { return nil }
        let words = utterance.norms
        let ordinals: [String: Int] = ["1st": 0, "first": 0, "one": 0, "1": 0, "2nd": 1, "second": 1, "two": 1, "2": 1,
                                       "3rd": 2, "third": 2, "three": 2, "3": 2, "4th": 3, "fourth": 3, "4": 3, "5th": 4, "5": 4]
        if words.contains("last") { return options.count - 1 }
        if words.count <= 4 {
            for word in words {
                if let index = ordinals[word], index < options.count { return index }
            }
        }
        // Name match: best token overlap.
        let spoken = Set(words)
        var best: (index: Int, score: Double)?
        for (index, option) in options.enumerated() {
            let optionWords = Utterance(option).norms
            guard !optionWords.isEmpty else { continue }
            let overlap = Double(optionWords.filter { spoken.contains($0) }.count)
            let score = overlap / Double(optionWords.count)
            if overlap > 0, score > (best?.score ?? 0) { best = (index, score) }
        }
        if let best, best.score >= 0.5 {
            // Reject ties (e.g. "Sam" when both options are Sams).
            let ties = options.enumerated().filter { index, option in
                index != best.index && {
                    let optionWords = Utterance(option).norms
                    let overlap = Double(optionWords.filter { spoken.contains($0) }.count)
                    return optionWords.isEmpty ? false : overlap / Double(optionWords.count) == best.score
                }()
            }
            return ties.isEmpty ? best.index : nil
        }
        return nil
    }
}
