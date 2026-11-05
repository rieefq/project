import Foundation

// MARK: - Weather

public struct GetWeatherTool: ToolHandler {
    let service: WeatherService

    public init(service: WeatherService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(
            name: "get_weather",
            description: "Current conditions and forecast for the user's location or a named place, for today or a specific day.",
            inputSchema: Schema.object([
                "place": Schema.string("City or place name; omit for the user's current location."),
                "when": Schema.string("Day, e.g. \"tomorrow\", \"Saturday\"; omit for now/today."),
                "focus": Schema.string("What the user cares about.", enum: ["general", "precipitation", "temperature"]),
            ]),
            capability: .weather, risk: .read)
    }

    func degrees(_ celsius: Double, metric: Bool) -> Int {
        Int((metric ? celsius : celsius * 9 / 5 + 32).rounded())
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        let place = arguments["place"]?.nonEmptyString
        if place == nil, let blocked = await Access.ensure(.weather, call: prepared.call, current: { await service.access() }, request: { await service.requestAccess() }) {
            return blocked
        }
        do {
            let report = try await service.report(for: place)
            let metric = context.usesMetric
            let calendar = context.temporal.calendar
            let formatter = context.formatter
            let focus = arguments["focus"]?.stringValue ?? "general"
            var targetDay = calendar.startOfDay(for: context.now)
            var dayPhrase = "today"
            if let when = arguments["when"]?.nonEmptyString, let parsed = context.parser.parse(when, purpose: .query) {
                targetDay = calendar.startOfDay(for: parsed.start)
                dayPhrase = formatter.day(parsed.start)
            }
            let isToday = calendar.isDate(targetDay, inSameDayAs: context.now)
            let forecast = report.daily.first { calendar.isDate($0.date, inSameDayAs: targetDay) }
            let placeSuffix = place.map { " in \(report.placeName.isEmpty ? $0 : report.placeName)" } ?? ""

            var sentences: [String] = []
            if isToday, let current = report.current {
                var sentence = "It's \(degrees(current.temperatureCelsius, metric: metric)) and \(current.condition.lowercased())\(placeSuffix)"
                if let apparent = current.apparentCelsius, abs(apparent - current.temperatureCelsius) >= 3 {
                    sentence += ", feels like \(degrees(apparent, metric: metric))"
                }
                sentences.append(sentence + ".")
            }
            if let forecast {
                let high = degrees(forecast.highCelsius, metric: metric)
                let low = degrees(forecast.lowCelsius, metric: metric)
                if isToday {
                    sentences.append("High of \(high), low of \(low).")
                } else {
                    sentences.append("\(dayPhrase.capitalizedFirst)\(placeSuffix): \(forecast.condition.lowercased()), with a high of \(high) and a low of \(low).")
                }
                let chance = Int((forecast.precipitationChance * 100).rounded())
                let kind = forecast.precipitationKind ?? "rain"
                if chance >= 60 {
                    sentences.append("\(kind.capitalizedFirst) is likely — about \(chance) percent.")
                } else if chance >= 25 {
                    sentences.append("There's a \(chance) percent chance of \(kind).")
                } else if focus == "precipitation" {
                    sentences.append("No \(kind) expected.")
                }
                // Hourly detail for today's rain timing.
                if isToday, chance >= 25 {
                    if let start = report.hourly.first(where: { $0.date > context.now && $0.precipitationChance >= 0.5 && calendar.isDate($0.date, inSameDayAs: context.now) }) {
                        sentences.append("Most likely around \(formatter.time(start.date)).")
                    }
                }
            }
            guard !sentences.isEmpty else {
                return .failed(ToolFailure(.notFound, message: "I don't have a forecast for \(dayPhrase) yet."))
            }
            var balanced = sentences.joined(separator: " ")
            var minimal = sentences.first ?? balanced
            if focus == "precipitation", let forecast {
                let chance = Int((forecast.precipitationChance * 100).rounded())
                let kind = forecast.precipitationKind ?? "rain"
                let answer = chance >= 50 ? "Yes, probably — \(chance) percent chance of \(kind)\(isToday ? "" : " \(dayPhrase)")." : chance >= 25 ? "Maybe — \(chance) percent chance of \(kind)." : "Probably not — \(chance) percent chance of \(kind)."
                minimal = answer
                balanced = answer + (sentences.first.map { " " + $0 } ?? "")
            }
            let temperatureText = report.current.map { "\(degrees($0.temperatureCelsius, metric: metric))°" }
                ?? forecast.map { "\(degrees($0.highCelsius, metric: metric))°" } ?? "—"
            let card = Card.weather(WeatherCard(
                place: report.placeName, temperature: isToday ? temperatureText : (forecast.map { "\(degrees($0.highCelsius, metric: metric))°" } ?? temperatureText),
                condition: (isToday ? report.current?.condition : forecast?.condition) ?? forecast?.condition ?? "",
                symbol: (isToday ? report.current?.symbol : forecast?.symbol) ?? "cloud",
                range: forecast.map { "H \(degrees($0.highCelsius, metric: metric))°  L \(degrees($0.lowCelsius, metric: metric))°" },
                attribution: report.attribution))
            return .completed(ActionResult(
                summary: "Weather for \(report.placeName) \(dayPhrase)",
                speech: SpeechPlan(minimal: minimal, balanced: balanced, detailed: balanced),
                card: card,
                data: [
                    "place": .string(report.placeName), "day": .string(dayPhrase), "units": .string(metric ? "celsius" : "fahrenheit"),
                    "current": report.current.map { ["temperature": .number(Double(degrees($0.temperatureCelsius, metric: metric))), "condition": .string($0.condition)] } ?? .null,
                    "forecast": forecast.map { [
                        "high": .number(Double(degrees($0.highCelsius, metric: metric))), "low": .number(Double(degrees($0.lowCelsius, metric: metric))),
                        "condition": .string($0.condition), "precipitation_chance": .number($0.precipitationChance),
                    ] } ?? .null,
                ],
                earcon: .none))
        } catch let failure as ToolFailure {
            return .failed(failure)
        } catch {
            return .failed(ToolFailure(.network, message: "I couldn't get the weather right now.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Places

private func placesAccess(_ service: PlacesService, _ call: ToolCall) async -> ToolOutcome? {
    await Access.ensure(.places, call: call, current: { await service.access() }, request: { await service.requestAccess() })
}

private func distanceText(_ meters: Double?, metric: Bool) -> String? {
    guard let meters else { return nil }
    if metric {
        return meters < 950 ? "\(Int((meters / 10).rounded() * 10)) meters" : String(format: "%.1f kilometers", meters / 1_000)
    }
    let miles = meters / 1_609.34
    if miles < 0.2 { return "\(Int((meters * 3.281 / 50).rounded() * 50)) feet" }
    if miles < 0.4 { return "a quarter mile" }
    if miles < 0.7 { return "half a mile" }
    return String(format: "%.1f miles", miles).replacingOccurrences(of: ".0 ", with: " ")
}

public struct FindPlacesTool: ToolHandler {
    let service: PlacesService

    public init(service: PlacesService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(name: "find_places", description: "Find nearby places or businesses (\"coffee\", \"pharmacy\", \"Blue Bottle\").",
                 inputSchema: Schema.object(["query": Schema.string("What to look for.")], required: ["query"]),
                 capability: .places, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await placesAccess(service, prepared.call) { return blocked }
        guard let query = prepared.call.arguments["query"]?.nonEmptyString else {
            return .needsInfo(SlotRequest(prompt: "What are you looking for?", parameter: "query", kind: .text, call: prepared.call))
        }
        do {
            let places = try await service.search(query).sorted { ($0.distanceMeters ?? .infinity) < ($1.distanceMeters ?? .infinity) }
            guard let first = places.first else {
                return .completed(ActionResult(summary: "No places for \(query)", speech: SpeechPlan("I couldn't find \(query) nearby."), earcon: .none))
            }
            let distance = distanceText(first.distanceMeters, metric: context.usesMetric)
            var balanced = "The closest is \(first.name)" + (distance.map { ", about \($0) away" } ?? "")
            if let address = first.address, !address.isEmpty { balanced += ", on \(address.components(separatedBy: ",").first ?? address)" }
            balanced += "."
            if places.count > 1 { balanced += " There's also \(places[1].name)." }
            return .completed(ActionResult(
                summary: "Found \(places.count) places for \(query)",
                speech: SpeechPlan(minimal: "\(first.name)" + (distance.map { ", \($0)" } ?? "") + ".", balanced: balanced, detailed: balanced),
                card: .place(PlaceCard(name: first.name, address: first.address, latitude: first.latitude, longitude: first.longitude, travelSummary: distance)),
                referent: Referent(kind: .place, id: first.id, title: first.name),
                data: ["places": .array(places.prefix(5).map { place -> JSONValue in
                    ["name": .string(place.name), "address": JSONValue(place.address), "distance_m": place.distanceMeters.map { .number($0.rounded()) } ?? .null]
                })],
                earcon: .none))
        } catch {
            return .failed(ToolFailure(.network, message: "I couldn't search maps right now.", detail: "\(error)", isRetryable: true))
        }
    }
}

private func resolveDestination(_ service: PlacesService, _ destination: String, context: ExecutionContext) async throws -> Place? {
    try await service.search(destination).first
}

public struct TravelTimeTool: ToolHandler {
    let service: PlacesService

    public init(service: PlacesService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(name: "get_travel_time", description: "How long it takes to get somewhere from the user's current location.",
                 inputSchema: Schema.object([
                    "destination": Schema.string("Place, address or business."),
                    "mode": Schema.string("Travel mode.", enum: ["driving", "walking", "transit"]),
                 ], required: ["destination"]),
                 capability: .places, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await placesAccess(service, prepared.call) { return blocked }
        guard let destination = prepared.call.arguments["destination"]?.nonEmptyString else {
            return .needsInfo(SlotRequest(prompt: "Where to?", parameter: "destination", kind: .place, call: prepared.call))
        }
        let mode = TravelMode(rawValue: prepared.call.arguments["mode"]?.stringValue ?? "driving") ?? .driving
        do {
            guard let place = try await resolveDestination(service, destination, context: context) else {
                return .failed(ToolFailure(.notFound, message: "I couldn't find \(destination)."))
            }
            let estimate = try await service.travel(to: place, mode: mode)
            let minutes = max(1, (estimate.seconds / 60).rounded())
            let duration = context.formatter.duration(minutes * 60)
            let modeText = mode == .driving ? "by car" : mode == .walking ? "on foot" : "by transit"
            let arrival = context.formatter.time(context.now.addingTimeInterval(estimate.seconds))
            let balanced = "About \(duration) \(modeText) to \(place.name). You'd get there around \(arrival)."
            return .completed(ActionResult(
                summary: "Travel time to \(place.name): \(Int(minutes)) min \(mode.rawValue)",
                speech: SpeechPlan(minimal: "About \(duration).", balanced: balanced, detailed: balanced),
                card: .place(PlaceCard(name: place.name, address: place.address, latitude: place.latitude, longitude: place.longitude,
                                       travelSummary: "\(duration) \(modeText)")),
                referent: Referent(kind: .place, id: place.id, title: place.name),
                data: ["destination": .string(place.name), "minutes": .number(minutes), "mode": .string(mode.rawValue)],
                earcon: .none))
        } catch {
            return .failed(ToolFailure(.network, message: "I couldn't work out the route right now.", detail: "\(error)", isRetryable: true))
        }
    }
}

public struct OpenDirectionsTool: ToolHandler {
    let service: PlacesService

    public init(service: PlacesService) { self.service = service }

    public var spec: ToolSpec {
        ToolSpec(name: "open_directions", description: "Open turn-by-turn directions to a place in Maps.",
                 inputSchema: Schema.object([
                    "destination": Schema.string("Place, address or business."),
                    "mode": Schema.string("Travel mode.", enum: ["driving", "walking", "transit"]),
                 ], required: ["destination"]),
                 capability: .places, risk: .reversible)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        if let blocked = await placesAccess(service, prepared.call) { return blocked }
        guard let destination = prepared.call.arguments["destination"]?.nonEmptyString else {
            return .needsInfo(SlotRequest(prompt: "Where to?", parameter: "destination", kind: .place, call: prepared.call))
        }
        let mode = TravelMode(rawValue: prepared.call.arguments["mode"]?.stringValue ?? "driving") ?? .driving
        do {
            guard let place = try await resolveDestination(service, destination, context: context) else {
                return .failed(ToolFailure(.notFound, message: "I couldn't find \(destination)."))
            }
            try await service.openDirections(to: place, mode: mode)
            return .completed(ActionResult(summary: "Opened directions to \(place.name)",
                                           speech: SpeechPlan(minimal: "Opening Maps.", balanced: "Here are directions to \(place.name).", detailed: nil),
                                           referent: Referent(kind: .place, id: place.id, title: place.name),
                                           data: ["destination": .string(place.name)], earcon: .success))
        } catch {
            return .failed(ToolFailure(.service, message: "I couldn't open Maps.", detail: "\(error)", isRetryable: true))
        }
    }
}

// MARK: - Time & date

public struct GetTimeTool: ToolHandler {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "get_time", description: "The current time (optionally in another city), today's date, the weekday of a date, or days until a date.",
                 inputSchema: Schema.object([
                    "question": Schema.string("What to answer.", enum: ["time", "date", "until"]),
                    "place": Schema.string("City for the time, e.g. \"Tokyo\"."),
                    "when": Schema.string("A date for \"date\"/\"until\", e.g. \"June 3rd\", \"Christmas\"."),
                 ]),
                 capability: .knowledge, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let arguments = prepared.call.arguments
        let question = arguments["question"]?.stringValue ?? "time"
        let formatter = context.formatter
        switch question {
        case "date":
            var date = context.now
            if let when = arguments["when"]?.nonEmptyString, let parsed = context.parser.parse(when, purpose: .query) { date = parsed.start }
            let isToday = context.temporal.calendar.isDate(date, inSameDayAs: context.now)
            let weekday = DateFormatter.localizedString(from: date, dateStyle: .full, timeStyle: .none)
            let text = isToday ? "It's \(weekday)." : "\(formatter.day(date).capitalizedFirst) is \(weekday)."
            return .completed(ActionResult(summary: "Date: \(weekday)", speech: SpeechPlan(text), data: ["date": .string(weekday)], earcon: .none))
        case "until":
            let target = arguments["when"]?.nonEmptyString ?? ""
            let holidays = ["christmas": "december 25", "new year's": "january 1", "new years": "january 1", "halloween": "october 31",
                            "valentine's day": "february 14", "independence day": "july 4", "new year's eve": "december 31"]
            let phrase = holidays[target.lowercased()] ?? target
            guard let parsed = context.parser.parse(phrase, purpose: .query) else {
                return .failed(ToolFailure(.invalidArguments, message: "Which date do you mean?"))
            }
            let calendar = context.temporal.calendar
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: context.now), to: calendar.startOfDay(for: parsed.start)).day ?? 0
            let text = days == 0 ? "That's today." : days == 1 ? "That's tomorrow." : "\(days) days — it's \(formatter.when(parsed.start, includeTime: false, includeWeekday: true).replacingOccurrences(of: "on ", with: ""))."
            return .completed(ActionResult(summary: "\(days) days until \(target)", speech: SpeechPlan(text), data: ["days": .number(Double(days))], earcon: .none))
        default:
            if let place = arguments["place"]?.nonEmptyString {
                guard let zone = WorldClock.timeZone(for: place) else {
                    return .failed(ToolFailure(.notFound, message: "I'm not sure what time zone \(place) is in."))
                }
                var zoned = context.temporal
                zoned.calendar.timeZone = zone
                let remote = SpokenFormatter(context: zoned, now: context.now)
                let localDay = context.temporal.calendar.component(.day, from: context.now)
                let remoteDay = zoned.calendar.component(.day, from: context.now)
                let dayNote = remoteDay == localDay ? "" : (remoteDay > localDay || (localDay > 27 && remoteDay < 3) ? " tomorrow" : " yesterday")
                let text = "It's \(remote.time(context.now))\(dayNote) in \(place.capitalizedFirst)."
                return .completed(ActionResult(summary: "Time in \(place)", speech: SpeechPlan(text), data: ["time": .string(remote.time(context.now))], earcon: .none))
            }
            let text = "It's \(formatter.time(context.now))."
            return .completed(ActionResult(summary: "Local time", speech: SpeechPlan(text), data: ["time": .string(formatter.time(context.now))], earcon: .none))
        }
    }
}

// MARK: - Calculator

public struct CalculateTool: ToolHandler {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "calculate", description: "Exact arithmetic, percentages and unit conversions (\"18% of 64\", \"5 km in miles\").",
                 inputSchema: Schema.object(["expression": Schema.string("The calculation in plain words or symbols.")], required: ["expression"]),
                 capability: .knowledge, risk: .read)
    }

    public func execute(_ prepared: PreparedCall, in context: ExecutionContext) async -> ToolOutcome {
        let expression = prepared.call.arguments["expression"]?.stringValue ?? ""
        let formatter = context.formatter
        if let conversion = UnitConverter.convert(expression) {
            let value = formatter.number(conversion.value)
            let result = formatter.number(conversion.result, maxFractionDigits: conversion.result < 10 ? 2 : 1)
            let text = "\(value) \(conversion.fromName) is about \(result) \(conversion.toName)."
            return .completed(ActionResult(summary: text, speech: SpeechPlan(text), data: ["result": .number(conversion.result)], earcon: .none))
        }
        guard let answer = Calculator.evaluate(expression) else {
            return .failed(ToolFailure(.invalidArguments, message: "I couldn't work that out."))
        }
        let text = "That's \(formatter.number(answer.value, maxFractionDigits: 4))."
        return .completed(ActionResult(summary: "\(expression) = \(answer.value)", speech: SpeechPlan(minimal: formatter.number(answer.value, maxFractionDigits: 4) + ".", balanced: text, detailed: text),
                                       data: ["result": .number(answer.value)], earcon: .none))
    }
}
