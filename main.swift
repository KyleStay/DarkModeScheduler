import SwiftUI
import AppKit
import Foundation
import ServiceManagement
import os

// =============================================================================
// Dark Mode Scheduler — a menu bar app that switches macOS to Dark at sunset
// and Light at sunrise, using sun times computed locally (NOAA algorithm in
// SunCalculator.swift) from a US zipcode the user enters.
//
// This file is the entire app. The pure sun math lives in SunCalculator.swift
// so it can be unit-tested without a GUI (see SunCalculatorTests.swift).
//
// Structure:
//   • Logger            — os.Logger instances.
//   • ResolvedLocation  — the geocoded {zip, lat, lon, city, state}.
//   • SettingsStore     — UserDefaults persistence.
//   • GeocodeService    — the only network use (zip → lat/long).
//   • AppearanceMode    — Light / Dark enum.
//   • AppearanceController — reads live appearance, applies via AppleScript,
//                            idempotent, handles the Automation permission.
//   • AppModel          — @MainActor ObservableObject: state, timer, wake,
//                          scheduling glue that the SwiftUI UI observes.
//   • PopoverView       — the MenuBarExtra popover UI.
//   • DarkModeSchedulerApp — the SwiftUI App / Scene.
//   • SelfTest          — the hidden `--selftest` CLI path (items 4 & 5).
//   • Top-level dispatch — routes `--selftest` vs normal launch.
// =============================================================================

// MARK: - Logging

enum Log {
    static let subsystem = "com.kyle.darkmodescheduler"
    static let appearance = Logger(subsystem: subsystem, category: "appearance")
    static let scheduler = Logger(subsystem: subsystem, category: "scheduler")
    static let geocode = Logger(subsystem: subsystem, category: "geocode")
    static let selftest = Logger(subsystem: subsystem, category: "selftest")
}

// MARK: - Model types

/// A resolved location cached in UserDefaults. Only re-fetched when the zip changes.
struct ResolvedLocation: Codable, Equatable {
    let zip: String
    let latitude: Double
    let longitude: Double
    let city: String
    let state: String

    var displayName: String { "\(city), \(state)" }
}

// MARK: - Settings persistence

/// Thin, typed wrapper over UserDefaults for the app's persisted state.
struct SettingsStore {
    private let defaults: UserDefaults
    private enum Key {
        static let location = "resolvedLocation"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

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
}

// MARK: - Geocoding (the only network use)

enum GeocodeError: LocalizedError, Equatable {
    case invalidZip
    case notFound
    case offline
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidZip: return "Enter a valid 5-digit US zipcode."
        case .notFound: return "No US location found for that zipcode."
        case .offline: return "Can't reach the network. Check your connection and try again."
        case .badResponse: return "Unexpected response from the geocoding service."
        }
    }
}

/// Resolves a US zipcode to a latitude/longitude and place name via the free,
/// key-less Zippopotam API. This is the app's only network call — sun times are
/// always computed locally.
struct GeocodeService {

    /// Shape of the api.zippopotam.us JSON response (keys contain spaces).
    private struct Response: Decodable {
        let places: [Place]
        struct Place: Decodable {
            let latitude: String
            let longitude: String
            let placeName: String
            let stateAbbreviation: String
            enum CodingKeys: String, CodingKey {
                case latitude, longitude
                case placeName = "place name"
                case stateAbbreviation = "state abbreviation"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func isValidZip(_ zip: String) -> Bool {
        zip.count == 5 && zip.allSatisfy { $0.isNumber }
    }

    /// Resolve a 5-digit zip. Throws a `GeocodeError` on any failure — never crashes.
    func resolve(zip: String) async throws -> ResolvedLocation {
        let trimmed = zip.trimmingCharacters(in: .whitespaces)
        guard Self.isValidZip(trimmed) else { throw GeocodeError.invalidZip }

        guard let url = URL(string: "https://api.zippopotam.us/us/\(trimmed)") else {
            throw GeocodeError.invalidZip
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Log.geocode.error("Network error for \(trimmed, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw GeocodeError.offline
        }

        guard let http = response as? HTTPURLResponse else { throw GeocodeError.badResponse }
        if http.statusCode == 404 { throw GeocodeError.notFound }
        guard http.statusCode == 200 else {
            Log.geocode.error("HTTP \(http.statusCode) for zip \(trimmed, privacy: .public)")
            throw GeocodeError.badResponse
        }

        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let place = decoded.places.first,
              let lat = Double(place.latitude),
              let lon = Double(place.longitude) else {
            throw GeocodeError.badResponse
        }

        let location = ResolvedLocation(zip: trimmed,
                                        latitude: lat,
                                        longitude: lon,
                                        city: place.placeName,
                                        state: place.stateAbbreviation)
        Log.geocode.info("Resolved \(trimmed, privacy: .public) → \(location.displayName, privacy: .public) (\(lat), \(lon))")
        return location
    }
}

// MARK: - Appearance control

enum AppearanceMode: String, Equatable {
    case light
    case dark

    var isDark: Bool { self == .dark }
    var label: String { self == .dark ? "Dark" : "Light" }
}

/// The result of one `enforce(...)` cycle, useful for logging and self-tests.
enum EnforceOutcome: Equatable {
    case unchanged(AppearanceMode)          // already correct → no AppleScript issued
    case applied(AppearanceMode)            // AppleScript issued, switch made
    case failedPermission                   // Automation permission not granted
    case failed(Int)                        // other AppleScript error (osastatus code)
}

/// Reads the live system appearance and applies changes idempotently via
/// AppleScript to System Events (the only method that live-updates the UI).
struct AppearanceController {

    /// The current live appearance, read from the global-domain preference that
    /// macOS keeps in sync (`AppleInterfaceStyle` == "Dark" when Dark).
    func currentMode() -> AppearanceMode {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
           style.lowercased() == "dark" {
            return .dark
        }
        return .light
    }

    /// Ensure the system appearance equals `desired`. Idempotent: if the live
    /// appearance already matches, **no AppleScript is issued** (no flicker).
    @discardableResult
    func enforce(desired: AppearanceMode) -> EnforceOutcome {
        let current = currentMode()
        guard current != desired else {
            Log.appearance.debug("enforce: already \(desired.label, privacy: .public); no AppleScript issued")
            return .unchanged(desired)
        }
        Log.appearance.info("enforce: \(current.label, privacy: .public) → \(desired.label, privacy: .public); issuing AppleScript")
        return apply(desired: desired)
    }

    /// Unconditionally apply `desired` via AppleScript. Prefer `enforce(desired:)`.
    @discardableResult
    func apply(desired: AppearanceMode) -> EnforceOutcome {
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(desired.isDark)"
        guard let script = NSAppleScript(source: source) else {
            Log.appearance.error("Failed to construct NSAppleScript")
            return .failed(-1)
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            // -1743 = errAEEventNotPermitted (Automation permission not granted).
            if code == -1743 {
                Log.appearance.error("AppleScript not permitted (-1743): Automation permission required")
                return .failedPermission
            }
            Log.appearance.error("AppleScript failed (\(code)): \(message, privacy: .public)")
            return .failed(code)
        }
        Log.appearance.info("Applied \(desired.label, privacy: .public)")
        return .applied(desired)
    }
}

// MARK: - App model (state + scheduling)

@MainActor
final class AppModel: ObservableObject {

    // Persisted / resolved location.
    @Published private(set) var location: ResolvedLocation?

    // UI state.
    @Published var zipInput: String = ""
    @Published private(set) var geocodeError: String?
    @Published private(set) var isResolving = false

    // Sun / schedule state.
    @Published private(set) var sunrise: SunEvent = .alwaysDown
    @Published private(set) var sunset: SunEvent = .alwaysDown
    @Published private(set) var scheduledMode: AppearanceMode = .light
    @Published private(set) var currentMode: AppearanceMode = .light
    @Published private(set) var permissionBlocked = false

    // Launch-at-login state.
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    var scheduledDark: Bool { scheduledMode.isDark }
    var scheduleMatches: Bool { currentMode == scheduledMode }

    private let settings = SettingsStore()
    private let geocoder = GeocodeService()
    private let appearance = AppearanceController()
    private let timeZone = TimeZone.current

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        location = settings.location
        zipInput = location?.zip ?? ""
        refreshLaunchAtLoginStatus()
        startTimer()
        observeWake()
        tick()  // evaluate & enforce immediately on launch
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: Scheduling

    private func startTimer() {
        // Re-evaluate every 60s. Tolerance lets macOS coalesce for efficiency.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.scheduler.info("System woke; re-evaluating schedule")
                self?.tick()
            }
        }
    }

    /// Recompute desired appearance from the current time & location and enforce it.
    func tick(now: Date = Date()) {
        currentMode = appearance.currentMode()

        guard let location else {
            // No location yet: reflect current appearance, do not enforce.
            scheduledMode = currentMode
            sunrise = .alwaysDown
            sunset = .alwaysDown
            return
        }

        let times = SunCalculator.sunTimes(latitude: location.latitude,
                                           longitude: location.longitude,
                                           date: now,
                                           timeZone: timeZone)
        sunrise = times.sunrise
        sunset = times.sunset

        let desired: AppearanceMode = Self.desiredMode(now: now, times: times) ? .dark : .light
        scheduledMode = desired

        let outcome = appearance.enforce(desired: desired)
        switch outcome {
        case .failedPermission: permissionBlocked = true
        default: permissionBlocked = false
        }
        currentMode = appearance.currentMode()
    }

    /// Desired-mode rule: Dark if now is at/after sunset or before sunrise.
    /// Polar fallbacks: never-rises → always Dark; never-sets → always Light.
    static func desiredMode(now: Date, times: SunTimes) -> Bool {
        switch times.sunrise {
        case .alwaysDown:
            return true    // sun never up → dark
        case .alwaysUp:
            return false   // sun never down → light
        case .time(let sr):
            guard case .time(let ss) = times.sunset else { return true }
            return now >= ss || now < sr
        }
    }

    // MARK: Zipcode changes

    func saveZip() {
        let trimmed = zipInput.trimmingCharacters(in: .whitespaces)
        guard GeocodeService.isValidZip(trimmed) else {
            geocodeError = GeocodeError.invalidZip.errorDescription
            return
        }
        // Only re-fetch when the zip actually changed.
        if let existing = location, existing.zip == trimmed {
            geocodeError = nil
            tick()
            return
        }

        geocodeError = nil
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let resolved = try await geocoder.resolve(zip: trimmed)
                settings.location = resolved
                location = resolved
                geocodeError = nil
                tick()  // immediately enforce for the new location
            } catch let error as GeocodeError {
                geocodeError = error.errorDescription
            } catch {
                geocodeError = GeocodeError.badResponse.errorDescription
            }
        }
    }

    // MARK: Launch at login

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.scheduler.error("Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)")
            launchAtLoginError = "Couldn't update Launch at Login: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    // MARK: Formatting helpers for the UI

    func formatted(_ event: SunEvent) -> String {
        switch event {
        case .time(let date):
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        case .alwaysUp: return "No sunset (polar day)"
        case .alwaysDown: return "No sunrise (polar night)"
        }
    }
}

// MARK: - UI

struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            zipSection

            if let location = model.location {
                Divider()
                locationSection(location)
            }

            Divider()

            settingsSection

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.scheduledDark ? "moon.stars.fill" : "sun.max.fill")
                .font(.title2)
                .foregroundStyle(model.scheduledDark ? Color.indigo : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Dark Mode Scheduler").font(.headline)
                Text("Scheduled: \(model.scheduledMode.label)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var zipSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("US Zipcode").font(.subheadline).bold()
            HStack {
                TextField("e.g. 10001", text: $model.zipInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onSubmit { model.saveZip() }
                Button("Save") { model.saveZip() }
                    .disabled(model.isResolving)
                if model.isResolving {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = model.geocodeError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func locationSection(_ location: ResolvedLocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "Location", value: location.displayName)
            row(label: "Sunrise", value: model.formatted(model.sunrise))
            row(label: "Sunset", value: model.formatted(model.sunset))
            row(label: "Current mode", value: model.currentMode.label)
            HStack {
                Image(systemName: model.scheduleMatches ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(model.scheduleMatches ? .green : .orange)
                Text(model.scheduleMatches
                     ? "Matches schedule"
                     : "Adjusting to \(model.scheduledMode.label)…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.permissionBlocked {
                permissionHint
            }
        }
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Automation permission needed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).bold().foregroundStyle(.orange)
            Text("Allow \"Dark Mode Scheduler\" to control System Events in\nSystem Settings → Privacy & Security → Automation, then try again.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Text("Launch at Login").font(.subheadline)
            }
            .toggleStyle(.switch)
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline).bold()
        }
    }
}

// MARK: - App

struct DarkModeSchedulerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Image(systemName: model.scheduledDark ? "moon.stars" : "sun.max")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Self test (hidden `--selftest` CLI path; not on the user path)

/// Command-line self-test used by build/CI verification. It exercises the
/// AppearanceController end to end WITHOUT launching the GUI:
///   • forces Dark then Light and confirms the live appearance flipped;
///   • confirms idempotency (no AppleScript issued when already at desired);
///   • restores the original appearance.
/// Exits 0 on success, non-zero on unexpected failure.
enum SelfTest {
    static func run() -> Never {
        let controller = AppearanceController()
        let original = controller.currentMode()
        print("=== Dark Mode Scheduler self-test ===")
        print("[selftest] original appearance: \(original.label)")

        let target: AppearanceMode = (original == .dark) ? .light : .dark
        var failures = 0

        // --- Item 4: force a switch and verify the live appearance changed. ---
        print("[selftest] forcing switch to \(target.label)…")
        let switchOutcome = controller.enforce(desired: target)
        print("[selftest]   → \(issued(switchOutcome))")
        switch switchOutcome {
        case .applied:
            let now = waitForMode(target, controller: controller)
            if now == target {
                print("[selftest] ✅ switched to \(target.label) (verified via AppleInterfaceStyle)")
            } else {
                print("[selftest] ❌ appearance did not change to \(target.label) (still \(now.label))")
                failures += 1
            }
        case .unchanged:
            print("[selftest] ❌ expected a switch but controller reported unchanged")
            failures += 1
        case .failedPermission:
            print("""
            [selftest] ⚠️ AUTOMATION PERMISSION REQUIRED (AppleScript error -1743).
                       A human must approve the prompt, or enable this binary under
                       System Settings → Privacy & Security → Automation → System Events.
                       Cannot verify the switch headlessly until then.
            """)
            failures += 1
        case .failed(let code):
            print("[selftest] ❌ AppleScript failed with code \(code)")
            failures += 1
        }

        // --- Item 5: idempotency — enforce same mode again → NO AppleScript. ---
        print("[selftest] enforcing \(target.label) again to check idempotency…")
        let repeatOutcome = controller.enforce(desired: target)
        print("[selftest]   → \(issued(repeatOutcome))")
        if case .unchanged = repeatOutcome {
            print("[selftest] ✅ idempotent: no AppleScript issued when already at desired")
        } else {
            print("[selftest] ❌ expected .unchanged, got \(repeatOutcome)")
            failures += 1
        }

        // --- Restore original appearance. ---
        print("[selftest] restoring original appearance (\(original.label))…")
        let restore = controller.enforce(desired: original)
        let restored = waitForMode(original, controller: controller)
        if restored == original {
            print("[selftest] ✅ restored to \(original.label) (outcome: \(restore))")
        } else {
            print("[selftest] ⚠️ could not confirm restore (now \(restored.label))")
        }

        print(failures == 0 ? "\n[selftest] ALL SELF-TESTS PASSED ✅" : "\n[selftest] \(failures) SELF-TEST(S) FAILED ❌")
        exit(failures == 0 ? 0 : 1)
    }

    /// Human-readable "was AppleScript issued?" derived from the real outcome.
    /// `.unchanged` is returned *only* from the branch that skips AppleScript,
    /// so this is a faithful readout of the idempotency decision.
    private static func issued(_ outcome: EnforceOutcome) -> String {
        switch outcome {
        case .unchanged: return "AppleScript issued: NO  (idempotent no-op)"
        case .applied: return "AppleScript issued: YES (state changed)"
        case .failedPermission: return "AppleScript issued: YES but blocked (permission -1743)"
        case .failed(let code): return "AppleScript issued: YES but failed (code \(code))"
        }
    }

    /// Poll `AppleInterfaceStyle` briefly; it can lag the AppleScript call.
    private static func waitForMode(_ target: AppearanceMode,
                                    controller: AppearanceController,
                                    timeout: TimeInterval = 3.0) -> AppearanceMode {
        let deadline = Date().addingTimeInterval(timeout)
        var mode = controller.currentMode()
        while mode != target && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            mode = controller.currentMode()
        }
        return mode
    }
}

// MARK: - Entry point
//
// main.swift permits top-level code. We intercept `--selftest` before starting
// the SwiftUI app so items 4 & 5 are scriptable without any GUI interaction.

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()  // never returns
}

DarkModeSchedulerApp.main()
