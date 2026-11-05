import Contacts
import CoreLocation
import Foundation
import LocalAuthentication
import MapKit
import UserNotifications
import WeatherKit
import AsideKit

// MARK: - Notifications

final class UserNotificationScheduler: NotificationScheduler, @unchecked Sendable {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func access() async -> AccessState {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> AccessState {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await access()
    }

    func schedule(_ notification: LocalNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = notification.category
        content.userInfo = notification.userInfo
        if notification.isTimeSensitive { content.interruptionLevel = .timeSensitive }
        let interval = max(1, notification.fireDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger))
    }

    func cancel(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func registerCategories() {
        let stop = UNNotificationAction(identifier: "timer.dismiss", title: "Dismiss", options: [])
        let timer = UNNotificationCategory(identifier: "timer", actions: [stop], intentIdentifiers: [], options: [])
        let talk = UNNotificationAction(identifier: "aside.talk", title: "Talk to Aside", options: [.foreground])
        let followUp = UNNotificationCategory(identifier: "followup", actions: [talk], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([timer, followUp])
    }
}

// MARK: - Location

/// One-shot, when-in-use location for weather, places and travel times.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate, LocationContextProvider {
    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var lastLocation: CLLocation?
    private var lastLocality: (name: String, location: CLLocation)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var state: AccessState {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> AccessState {
        guard state == .notDetermined else { return state }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
        return state
    }

    func current() async -> CLLocation? {
        if let lastLocation, lastLocation.timestamp.timeIntervalSinceNow > -300 { return lastLocation }
        guard state.isUsable else { return nil }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    nonisolated func approximateLocality() async -> String? {
        await locality()
    }

    private func locality() async -> String? {
        guard state.isUsable, let location = await current() else { return nil }
        if let cached = lastLocality, cached.location.distance(from: location) < 3_000 { return cached.name }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }
        let name = [placemark.locality, placemark.administrativeArea, placemark.isoCountryCode].compactMap { $0 }.joined(separator: ", ")
        lastLocality = (name, location)
        return name.isEmpty ? nil : name
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            let waiters = authorizationWaiters
            authorizationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            lastLocation = locations.last
            let waiters = locationWaiters
            locationWaiters.removeAll()
            waiters.forEach { $0.resume(returning: locations.last) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let waiters = locationWaiters
            locationWaiters.removeAll()
            waiters.forEach { $0.resume(returning: lastLocation) }
        }
    }
}

// MARK: - Places

final class MapKitPlaces: PlacesService, @unchecked Sendable {
    private let location: LocationProvider

    init(location: LocationProvider) { self.location = location }

    func access() async -> AccessState { await location.state }
    func requestAccess() async -> AccessState { await location.requestAccess() }

    func search(_ query: String) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let here = await location.current()
        if let here {
            request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 25_000, longitudinalMeters: 25_000)
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).map { item in
            let coordinate = item.placemark.coordinate
            let itemLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return Place(id: "\(coordinate.latitude),\(coordinate.longitude)", name: item.name ?? query,
                         address: item.placemark.title, latitude: coordinate.latitude, longitude: coordinate.longitude,
                         distanceMeters: here.map { $0.distance(from: itemLocation) }, phone: item.phoneNumber)
        }
    }

    func travel(to place: Place, mode: TravelMode) async throws -> TravelEstimate {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = Self.mapItem(place)
        request.transportType = Self.transport(mode)
        let eta = try await MKDirections(request: request).calculateETA()
        return TravelEstimate(place: place, mode: mode, seconds: eta.expectedTravelTime, distanceMeters: eta.distance)
    }

    func openDirections(to place: Place, mode: TravelMode) async throws {
        let item = Self.mapItem(place)
        let modeKey: String
        switch mode {
        case .driving: modeKey = MKLaunchOptionsDirectionsModeDriving
        case .walking: modeKey = MKLaunchOptionsDirectionsModeWalking
        case .transit: modeKey = MKLaunchOptionsDirectionsModeTransit
        }
        await MainActor.run {
            _ = item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: modeKey])
        }
    }

    static func mapItem(_ place: Place) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)))
        item.name = place.name
        return item
    }

    static func transport(_ mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .driving: return .automobile
        case .walking: return .walking
        case .transit: return .transit
        }
    }
}

// MARK: - Weather

final class AppleWeather: WeatherProvider, @unchecked Sendable {
    private let location: LocationProvider

    init(location: LocationProvider) { self.location = location }

    func access() async -> AccessState { await location.state }
    func requestAccess() async -> AccessState { await location.requestAccess() }

    func report(for place: String?) async throws -> WeatherReport {
        let target: CLLocation
        var name = ""
        if let place {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = place
            request.resultTypes = .address
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else {
                throw ToolFailure(.notFound, message: "I couldn't find \(place).")
            }
            let coordinate = item.placemark.coordinate
            target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            name = item.placemark.locality ?? item.name ?? place
        } else {
            guard let here = await location.current() else {
                throw ToolFailure(.unavailable, message: "I couldn't get your location for the weather.")
            }
            target = here
            name = await location.approximateLocality()?.components(separatedBy: ",").first ?? "here"
        }
        let weather = try await WeatherKit.WeatherService.shared.weather(for: target)
        let current = weather.currentWeather
        let conditions = CurrentConditions(temperatureCelsius: current.temperature.converted(to: .celsius).value,
                                           apparentCelsius: current.apparentTemperature.converted(to: .celsius).value,
                                           condition: current.condition.description, symbol: current.symbolName)
        let daily = weather.dailyForecast.forecast.prefix(10).map { day in
            DailyForecast(date: day.date, highCelsius: day.highTemperature.converted(to: .celsius).value,
                          lowCelsius: day.lowTemperature.converted(to: .celsius).value, condition: day.condition.description,
                          symbol: day.symbolName, precipitationChance: day.precipitationChance,
                          precipitationKind: day.precipitation == Precipitation.none ? nil : day.precipitation.description.lowercased())
        }
        let hourly = weather.hourlyForecast.forecast.prefix(24).map { hour in
            HourlyForecast(date: hour.date, temperatureCelsius: hour.temperature.converted(to: .celsius).value,
                           precipitationChance: hour.precipitationChance, condition: hour.condition.description)
        }
        let attribution = try? await WeatherKit.WeatherService.shared.attribution
        return WeatherReport(placeName: name, current: conditions, daily: Array(daily), hourly: Array(hourly),
                             attribution: attribution?.serviceName ?? "Apple Weather")
    }
}

// MARK: - Contacts

final class SystemContacts: ContactsService, @unchecked Sendable {
    private let store = CNContactStore()

    private static let synonyms: [String: [String]] = [
        "mom": ["mom", "mum", "mother", "mama"], "mum": ["mum", "mom", "mother"], "mother": ["mother", "mom", "mum"],
        "dad": ["dad", "father", "papa"], "father": ["father", "dad"],
    ]

    func access() async -> AccessState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        #if os(iOS)
        case .limited: return .limited
        #endif
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> AccessState {
        _ = try? await store.requestAccess(for: .contacts)
        return await access()
    }

    func find(_ name: String) async throws -> [ContactMatch] {
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                                       CNContactPhoneNumbersKey, CNContactEmailAddressesKey].map { $0 as CNKeyDescriptor }
        let lowered = name.lowercased().replacingOccurrences(of: "my ", with: "")
        var results: [CNContact] = []
        for term in Self.synonyms[lowered] ?? [name] {
            let predicate = CNContact.predicateForContacts(matchingName: term)
            results += (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
            if !results.isEmpty { break }
        }
        var seen = Set<String>()
        return results.compactMap { contact in
            guard seen.insert(contact.identifier).inserted else { return nil }
            var handles: [ContactHandle] = contact.phoneNumbers.map { labeled in
                ContactHandle(kind: .phone, value: labeled.value.stringValue,
                              label: labeled.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) })
            }
            handles += contact.emailAddresses.map { ContactHandle(kind: .email, value: String($0.value)) }
            let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let display = !full.isEmpty ? full : (!contact.nickname.isEmpty ? contact.nickname : contact.organizationName)
            return ContactMatch(id: contact.identifier, name: display, handles: handles)
        }
    }
}

// MARK: - Device authentication

struct BiometricAuthenticator: DeviceAuthenticator {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
