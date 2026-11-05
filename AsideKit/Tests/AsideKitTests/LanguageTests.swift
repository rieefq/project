import Foundation
import Testing
@testable import AsideKit

@Suite("Tokenizer and numbers")
struct TokenizerTests {
    @Test func normalizesNumberWordsAndKeepsOriginals() {
        let utterance = Utterance("Remind me in thirty days to change my toothbrush")
        #expect(utterance.norms == ["remind", "me", "in", "30", "days", "to", "change", "my", "toothbrush"])
        #expect(utterance.original(3..<5) == "thirty days")
    }

    @Test func splitsGluedMeridiemsAndHyphenatedNumbers() {
        #expect(Utterance("at 5pm").norms == ["at", "5", "pm"])
        #expect(Utterance("at 5:30PM").norms == ["at", "5:30", "pm"])
        #expect(Utterance("twenty-five minutes").norms == ["25", "minutes"])
        #expect(Utterance("a 5-minute timer").norms == ["a", "5", "minute", "timer"])
        #expect(Utterance("at 9 a.m.").norms == ["at", "9", "am"])
    }

    @Test func dropsFillersAndPunctuation() {
        #expect(Utterance("Um, set a timer, uh, for ten minutes!").norms == ["set", "a", "timer", "for", "10", "minutes"])
    }

    @Test func compoundNumbers() {
        #expect(NumberWords.cardinal(["one", "hundred", "and", "five"]) == 105)
        #expect(NumberWords.cardinal(["two", "thousand", "twenty", "six"]) == 2026)
        #expect(NumberWords.cardinal(["a", "hundred"]) == 100)
        #expect(Utterance("the twenty first").norms == ["the", "21st"])
        #expect(Utterance("june third").norms == ["june", "3rd"])
    }
}

@Suite("Durations")
struct DurationTests {
    @Test(arguments: [
        ("10 minutes", 600.0),
        ("an hour and a half", 5_400.0),
        ("half an hour", 1_800.0),
        ("1 hour and 30 minutes", 5_400.0),
        ("90 seconds", 90.0),
        ("2 and a half hours", 9_000.0),
        ("a couple of minutes", 120.0),
        ("a quarter of an hour", 900.0),
    ])
    func parses(_ text: String, _ seconds: Double) {
        let duration = DurationParser.parseWhole(Utterance(text).norms)
        #expect(duration?.approximateSeconds == seconds)
    }

    @Test func calendarUnitsStaySeparate() {
        let duration = DurationParser.parseWhole(Utterance("30 days").norms)
        #expect(duration?.days == 30)
        #expect(duration?.isClockOnly == false)
    }

    @Test func rejectsNonDurations() {
        #expect(DurationParser.parseWhole(Utterance("a reminder").norms) == nil)
        #expect(DurationParser.parseWhole(Utterance("5 apples").norms) == nil)
    }
}

@Suite("Temporal parser — scheduling (Thu Nov 5 2026, 2:30 PM)")
struct TemporalScheduleTests {
    let parser = TemporalParser(calendar: testCalendar, now: referenceNow, locale: Locale(identifier: "en_US"))

    func start(_ text: String) -> Date? { parser.parse(text, purpose: .schedule)?.start }

    @Test func relativeOffsets() {
        #expect(start("in 30 days") == date(2026, 12, 5, 14, 30))
        #expect(start("in 2 hours") == date(2026, 11, 5, 16, 30))
        #expect(start("in 20 minutes") == date(2026, 11, 5, 14, 50))
        #expect(start("in an hour and a half") == date(2026, 11, 5, 16, 0))
        #expect(start("in 2 weeks") == date(2026, 11, 19, 14, 30))
        #expect(start("45 minutes from now") == date(2026, 11, 5, 15, 15))
        #expect(parser.parse("in 30 days", purpose: .schedule)?.hasExplicitTime == false)
        #expect(parser.parse("in 2 hours", purpose: .schedule)?.hasExplicitTime == true)
    }

    @Test func daysAndTimes() {
        #expect(start("tomorrow at 9") == date(2026, 11, 6, 9, 0))
        #expect(start("tomorrow at 9pm") == date(2026, 11, 6, 21, 0))
        #expect(start("tomorrow morning") == date(2026, 11, 6, 9, 0))
        #expect(start("the day after tomorrow at 3") == date(2026, 11, 7, 15, 0))
        #expect(start("tonight") == date(2026, 11, 5, 20, 0))
        #expect(start("tonight at 8") == date(2026, 11, 5, 20, 0))
        #expect(start("this evening") == date(2026, 11, 5, 18, 0))
        #expect(start("first thing tomorrow") == date(2026, 11, 6, 8, 0))
    }

    @Test func bareTimesPickTheNextSensibleOccurrence() {
        #expect(start("at 5") == date(2026, 11, 5, 17, 0))
        #expect(start("at 1") == date(2026, 11, 6, 13, 0))
        #expect(start("at noon") == date(2026, 11, 6, 12, 0))
        #expect(start("at midnight") == date(2026, 11, 6, 0, 0))
        #expect(start("10:30 pm") == date(2026, 11, 5, 22, 30))
        #expect(start("at 17:45") == date(2026, 11, 5, 17, 45))
        #expect(start("half past 4") == date(2026, 11, 5, 16, 30))
        #expect(start("quarter to 6") == date(2026, 11, 5, 17, 45))
    }

    @Test func weekdays() {
        #expect(start("friday") == date(2026, 11, 6, 9, 0))
        #expect(start("next friday") == date(2026, 11, 13, 9, 0))
        #expect(start("next monday") == date(2026, 11, 9, 9, 0))
        #expect(start("on monday at 10am") == date(2026, 11, 9, 10, 0))
        #expect(start("thursday") == date(2026, 11, 12, 9, 0))
        #expect(start("thursday at 5pm") == date(2026, 11, 5, 17, 0))
    }

    @Test func dates() {
        #expect(start("june 3rd") == date(2027, 6, 3, 9, 0))
        #expect(start("december 25") == date(2026, 12, 25, 9, 0))
        #expect(start("on the 15th") == date(2026, 11, 15, 9, 0))
        #expect(start("the 3rd of january") == date(2027, 1, 3, 9, 0))
        #expect(start("on 12/24") == date(2026, 12, 24, 9, 0))
        #expect(start("2026-12-05") == date(2026, 12, 5, 9, 0))
    }

    @Test func periods() {
        #expect(start("next week") == date(2026, 11, 9, 9, 0))
        #expect(start("this weekend") == date(2026, 11, 7, 10, 0))
        #expect(start("by the end of the month") == date(2026, 11, 30, 17, 0))
        #expect(start("end of the week") == date(2026, 11, 6, 17, 0))
    }

    @Test func recurrence() {
        let monday = parser.parse("every monday at 8am", purpose: .schedule)
        #expect(monday?.start == date(2026, 11, 9, 8, 0))
        #expect(monday?.recurrence == RecurrenceRule(frequency: .weekly, weekdays: [2]))
        let daily = parser.parse("every day at 7", purpose: .schedule)
        #expect(daily?.start == date(2026, 11, 6, 7, 0))
        #expect(daily?.recurrence?.frequency == .daily)
        #expect(parser.parse("every weekday", purpose: .schedule)?.recurrence?.weekdays == [2, 3, 4, 5, 6])
    }

    @Test func pastTimesAreFlagged() {
        #expect(parser.parse("today at 9am", purpose: .schedule)?.isInPast == true)
    }

    @Test func consumedTokensAllowTitleExtraction() {
        let utterance = Utterance("call mom tomorrow at 9")
        let result = parser.parse(utterance, purpose: .schedule)
        #expect(result?.consumed == [2, 3, 4])
    }
}

@Suite("Temporal parser — questions")
struct TemporalQueryTests {
    let parser = TemporalParser(calendar: testCalendar, now: referenceNow, locale: Locale(identifier: "en_US"))

    @Test func intervals() {
        let tomorrow = parser.parse("tomorrow", purpose: .query)
        #expect(tomorrow?.start == date(2026, 11, 6) && tomorrow?.end == date(2026, 11, 7))
        let afternoon = parser.parse("this afternoon", purpose: .query)
        #expect(afternoon?.start == date(2026, 11, 5, 12) && afternoon?.end == date(2026, 11, 5, 17))
        let nextWeek = parser.parse("next week", purpose: .query)
        #expect(nextWeek?.start == date(2026, 11, 8) && nextWeek?.end == date(2026, 11, 15))
        let weekend = parser.parse("this weekend", purpose: .query)
        #expect(weekend?.start == date(2026, 11, 7) && weekend?.end == date(2026, 11, 9))
        let friday = parser.parse("on friday", purpose: .query)
        #expect(friday?.start == date(2026, 11, 6) && friday?.end == date(2026, 11, 7))
    }
}

@Suite("Spoken formatting")
struct SpokenFormatterTests {
    let formatter = SpokenFormatter(context: testTemporal, now: referenceNow)

    @Test func relativeDays() {
        #expect(formatter.when(date(2026, 11, 6, 9), includeTime: true) == "tomorrow at 9 AM")
        #expect(formatter.when(date(2026, 11, 5, 17), includeTime: true) == "at 5 PM")
        #expect(formatter.when(date(2026, 11, 9, 12), includeTime: true) == "on Monday at noon")
        #expect(formatter.when(date(2026, 12, 5, 14, 30), includeTime: false) == "on December 5th")
        #expect(formatter.when(date(2026, 12, 5, 14, 30), includeTime: false, includeWeekday: true) == "on Saturday, December 5th")
    }

    @Test func durationsAndLists() {
        #expect(formatter.duration(600) == "10 minutes")
        #expect(formatter.duration(5_400) == "an hour and a half")
        #expect(formatter.duration(3_900) == "1 hour and 5 minutes")
        #expect(formatter.list(["a", "b", "c"]) == "a, b, and c")
    }

    @Test func perspective() {
        #expect(PerspectiveShifter.secondPerson("change my toothbrush") == "change your toothbrush")
        #expect(PerspectiveShifter.secondPerson("I am late") == "you are late")
    }

    @Test func sanitizesMarkdownForSpeech() {
        #expect(SpeechText.sanitize("**Paris** is the capital. See [this](https://x.com).") == "Paris is the capital. See this.")
        #expect(!SpeechText.sanitize("- one\n- two").contains("-"))
    }

    @Test func chunksSentencesEarly() {
        var chunker = SentenceChunker()
        var chunks = chunker.append("It's 64 and cloudy. High of")
        chunks += chunker.append(" 70 later. Dr. Lee is in.")
        #expect(chunks == ["It's 64 and cloudy.", "High of 70 later."])
        #expect(chunker.flush() == "Dr. Lee is in.")
    }
}

@Suite("Quick answers")
struct QuickAnswerTests {
    @Test func arithmetic() {
        #expect(Calculator.evaluate("what's 18% of 64")?.value == 11.52)
        #expect(Calculator.evaluate("3 plus 4 times 2")?.value == 11)
        #expect(Calculator.evaluate("square root of 81")?.value == 9)
        #expect(Calculator.evaluate("10 divided by 4")?.value == 2.5)
        #expect(Calculator.evaluate("2 to the power of 10")?.value == 1024)
        #expect(Calculator.evaluate("what's the weather") == nil)
    }

    @Test func conversions() {
        let miles = UnitConverter.convert("5 km in miles")
        #expect(miles != nil && abs(miles!.result - 3.10686) < 0.001)
        let cup = UnitConverter.convert("how many ounces in a cup")
        #expect(cup != nil && abs(cup!.result - 8.0) < 0.5)
        let temperature = UnitConverter.convert("72 fahrenheit in celsius")
        #expect(temperature != nil && abs(temperature!.result - 22.22) < 0.01)
    }

    @Test func worldClock() {
        #expect(WorldClock.timeZone(for: "Tokyo")?.identifier == "Asia/Tokyo")
        #expect(WorldClock.timeZone(for: "new york")?.identifier == "America/New_York")
    }
}
