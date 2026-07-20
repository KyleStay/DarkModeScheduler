import Foundation
import os

// =============================================================================
// Support.swift — logging, the resolved-location model, error types, and the
// UserDefaults-backed settings store (with v1 → v2 migration).
// =============================================================================

// MARK: - Logging

enum Log {
    static let subsystem = "com.kyle.darkmodescheduler"
    static let appearance = Logger(subsystem: subsystem, category: "appearance")
    static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    static let geocode = Logger(subsystem: subsystem, category: "geocode")
    static let location = Logger(subsystem: subsystem, category: "location")
    static let nightshift = Logger(subsystem: subsystem, category: "nightshift")
    static let notify = Logger(subsystem: subsystem, category: "notify")
    static let selftest = Logger(subsystem: subsystem, category: "selftest")
}

// MARK: - Resolved location

/// How the app's coordinates were obtained.
enum LocationSource: String, Equatable, Codable {
    case zip          // manual postal code (default, always available)
    case coreLocation // Location Services (optional)

    var label: String { self == .coreLocation ? "My Location" : "Postal code" }
}

/// A resolved location cached in UserDefaults. Only re-fetched when the postal
/// code (or country) changes, or when Location Services provides a new fix.
///
/// `zip` holds the postal code / identifier; `country` is an ISO-3166 alpha-2
/// code. v1 archives lacked `country` — `init(from:)` defaults it to "US" so old
/// state migrates transparently.
struct ResolvedLocation: Codable, Equatable {
    let zip: String
    let latitude: Double
    let longitude: Double
    let city: String
    let state: String
    let country: String
    let source: LocationSource

    init(zip: String, latitude: Double, longitude: Double,
         city: String, state: String, country: String = "US",
         source: LocationSource = .zip) {
        self.zip = zip
        self.latitude = latitude
        self.longitude = longitude
        self.city = city
        self.state = state
        self.country = country
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        zip = try c.decode(String.self, forKey: .zip)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        city = try c.decode(String.self, forKey: .city)
        state = try c.decode(String.self, forKey: .state)
        country = (try c.decodeIfPresent(String.self, forKey: .country)) ?? "US"
        source = (try c.decodeIfPresent(LocationSource.self, forKey: .source)) ?? .zip
    }

    /// "City, ST" for US; appends the country for non-US so it's unambiguous.
    var displayName: String {
        let region = state.isEmpty ? "" : ", \(state)"
        if country.uppercased() == "US" {
            return "\(city)\(region)"
        }
        return "\(city)\(region) (\(country.uppercased()))"
    }
}

// MARK: - Geocoding errors

enum GeocodeError: LocalizedError, Equatable {
    case invalidZip
    case invalidPostal
    case notFound
    case offline
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidZip: return "Enter a valid 5-digit US zipcode."
        case .invalidPostal: return "Enter a valid postal code for the selected country."
        case .notFound: return "No location found for that postal code."
        case .offline: return "Can't reach the network. Check your connection and try again."
        case .badResponse: return "Unexpected response from the geocoding service."
        }
    }
}

// MARK: - Settings store (UserDefaults, typed, with v1 migration)

/// Thin, typed wrapper over UserDefaults for all persisted state. Every property
/// has a sane default, so a fresh install and a migrated v1 install both read
/// cleanly (v1 only ever wrote `resolvedLocation`).
struct SettingsStore {

    /// Offsets are clamped to this range (minutes) in both directions.
    static let offsetRange = -180...180

    private let defaults: UserDefaults
    private enum Key {
        static let location = "resolvedLocation"
        static let scheduleMode = "scheduleMode"
        // Keep the pre-2.8 storage names so existing schedules migrate in place.
        static let fixedNighttimeMinutes = "fixedDarkMinutes"
        static let fixedDaytimeMinutes = "fixedLightMinutes"
        static let nighttimeOffsetMinutes = "darkOffsetMinutes"
        static let daytimeOffsetMinutes = "lightOffsetMinutes"
        static let locationSource = "locationSource"
        static let notificationsEnabled = "notificationsEnabled"
        static let darkAppearanceEnabled = "darkAppearanceEnabled"
        static let nightShiftEnabled = "nightShiftEnabled"
        static let nightShiftOwnedActive = "nightShiftOwnedActive"
        static let nightShiftCleanupPending = "nightShiftCleanupPending"
        static let override = "override"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Location

    var location: ResolvedLocation? {
        get {
            guard let data = defaults.data(forKey: Key.location) else { return nil }
            return try? JSONDecoder().decode(ResolvedLocation.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.location)
            } else {
                defaults.removeObject(forKey: Key.location)
            }
        }
    }

    // MARK: Schedule mode

    var scheduleMode: ScheduleMode {
        get { ScheduleMode(rawValue: defaults.string(forKey: Key.scheduleMode) ?? "") ?? .sun }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.scheduleMode) }
    }

    // MARK: Fixed times (minutes since local midnight)

    /// Default fixed schedule: Dark at 20:00, Light at 07:00.
    var fixedNighttimeMinutes: Int {
        get { defaults.object(forKey: Key.fixedNighttimeMinutes) as? Int ?? 20 * 60 }
        nonmutating set { defaults.set(clampMinuteOfDay(newValue), forKey: Key.fixedNighttimeMinutes) }
    }

    var fixedDaytimeMinutes: Int {
        get { defaults.object(forKey: Key.fixedDaytimeMinutes) as? Int ?? 7 * 60 }
        nonmutating set { defaults.set(clampMinuteOfDay(newValue), forKey: Key.fixedDaytimeMinutes) }
    }

    // MARK: Sun offsets (minutes; +/- offsetRange)

    var nighttimeOffsetMinutes: Int {
        get { defaults.object(forKey: Key.nighttimeOffsetMinutes) as? Int ?? 0 }
        nonmutating set { defaults.set(clampOffset(newValue), forKey: Key.nighttimeOffsetMinutes) }
    }

    var daytimeOffsetMinutes: Int {
        get { defaults.object(forKey: Key.daytimeOffsetMinutes) as? Int ?? 0 }
        nonmutating set { defaults.set(clampOffset(newValue), forKey: Key.daytimeOffsetMinutes) }
    }

    // MARK: Location source

    var locationSource: LocationSource {
        get { LocationSource(rawValue: defaults.string(forKey: Key.locationSource) ?? "") ?? .zip }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.locationSource) }
    }

    // MARK: Feature toggles

    var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }   // default false
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// Missing on builds through 2.7, where Dark appearance was mandatory.
    /// Defaulting absent storage to true preserves every existing schedule.
    var darkAppearanceEnabled: Bool {
        get { defaults.object(forKey: Key.darkAppearanceEnabled) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.darkAppearanceEnabled) }
    }

    var nightShiftEnabled: Bool {
        get { defaults.bool(forKey: Key.nightShiftEnabled) }      // default false
        nonmutating set { defaults.set(newValue, forKey: Key.nightShiftEnabled) }
    }

    /// Internal recovery state. Ownership is set only after the app proves it
    /// changed Night Shift on, so user-owned warmth is preserved on opt-out.
    var nightShiftOwnedActive: Bool {
        get { defaults.bool(forKey: Key.nightShiftOwnedActive) }
        nonmutating set { defaults.set(newValue, forKey: Key.nightShiftOwnedActive) }
    }

    var nightShiftCleanupPending: Bool {
        get { defaults.bool(forKey: Key.nightShiftCleanupPending) }
        nonmutating set { defaults.set(newValue, forKey: Key.nightShiftCleanupPending) }
    }

    var scheduleEffects: ScheduleEffects {
        ScheduleEffects(darkAppearance: darkAppearanceEnabled,
                        nightShift: nightShiftEnabled)
    }

    // MARK: Override (persisted across relaunch)

    var override: Override? {
        get {
            guard let data = defaults.data(forKey: Key.override) else { return nil }
            return try? JSONDecoder().decode(Override.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.override)
            } else {
                defaults.removeObject(forKey: Key.override)
            }
        }
    }

    // MARK: Clamping helpers

    private func clampOffset(_ value: Int) -> Int {
        min(max(value, Self.offsetRange.lowerBound), Self.offsetRange.upperBound)
    }

    private func clampMinuteOfDay(_ value: Int) -> Int {
        min(max(value, 0), 24 * 60 - 1)
    }
}
