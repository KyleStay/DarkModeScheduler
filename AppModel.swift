import SwiftUI
import AppKit
import Foundation
import Combine
import CoreLocation
import ServiceManagement

// =============================================================================
// AppModel.swift — the @MainActor orchestrator the SwiftUI UI observes.
//
// It owns the published state, the 60s timer, wake handling, and the glue that
// runs each evaluation through the pure EnforcementEngine and applies the
// resulting side effects (appearance, Night Shift, notifications, persistence).
// All scheduling *decisions* live in Scheduler.swift; this file only wires them
// to the real system.
// =============================================================================

@MainActor
final class AppModel: ObservableObject {

    // MARK: Location / geocoding state
    @Published private(set) var location: ResolvedLocation?
    @Published var zipInput: String = ""
    @Published var countryInput: String = "US"
    @Published private(set) var geocodeError: String?
    @Published private(set) var isResolving = false

    // MARK: Location source (zip vs CoreLocation)
    @Published var locationSource: LocationSource = .zip
    @Published private(set) var locationAuthStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var locationError: String?

    // MARK: Sun / schedule display
    @Published private(set) var sunrise: SunEvent = .alwaysDown
    @Published private(set) var sunset: SunEvent = .alwaysDown
    @Published private(set) var scheduledMode: AppearanceMode = .light
    @Published private(set) var currentMode: AppearanceMode = .light
    @Published private(set) var nextTransition: Transition?
    @Published private(set) var permissionBlocked = false

    // MARK: Mode + tuning
    @Published var scheduleMode: ScheduleMode = .sun
    @Published var fixedDarkMinutes: Int = 20 * 60
    @Published var fixedLightMinutes: Int = 7 * 60
    @Published var darkOffsetMinutes: Int = 0
    @Published var lightOffsetMinutes: Int = 0

    // MARK: Overrides / pause
    @Published private(set) var override: Override?

    // MARK: Feature toggles
    @Published var notificationsEnabled = false
    @Published var nightShiftEnabled = false
    @Published private(set) var nightShiftAvailable = false

    // MARK: Launch at login
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    // MARK: Glance
    @Published private(set) var glanceText = "Dark Mode Scheduler"

    // Derived helpers used by the UI.
    var scheduledDark: Bool { scheduledMode.isDark }
    var scheduleMatches: Bool { currentMode == scheduledMode }
    var isOverridden: Bool { override != nil }

    // MARK: Collaborators
    private let settings = SettingsStore()
    private let geocoder = GeocodeService()
    private let appearance = AppearanceController()
    private let notifications = NotificationService()
    private let nightShift: NightShiftControlling = CoreBrightnessNightShift()
    let locationService = LocationService()
    private let timeZone = TimeZone.current

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// The mode the app believes it last put in effect (or accepted). Seeds the
    /// manual-divergence detection so the first tick never false-triggers.
    private var lastEnforced: AppearanceMode = .light
    /// Dedup for Night Shift calls.
    private var lastNightShiftActive: Bool?

    init() {
        // Load persisted settings into published mirrors.
        location = settings.location
        scheduleMode = settings.scheduleMode
        fixedDarkMinutes = settings.fixedDarkMinutes
        fixedLightMinutes = settings.fixedLightMinutes
        darkOffsetMinutes = settings.darkOffsetMinutes
        lightOffsetMinutes = settings.lightOffsetMinutes
        locationSource = settings.locationSource
        notificationsEnabled = settings.notificationsEnabled
        nightShiftEnabled = settings.nightShiftEnabled
        override = settings.override
        nightShiftAvailable = nightShift.isAvailable

        zipInput = location?.source == .zip ? (location?.zip ?? "") : ""
        countryInput = location?.country ?? "US"

        // Seed the divergence baseline to the live appearance.
        lastEnforced = appearance.currentMode()
        locationAuthStatus = locationService.authorizationStatus

        wireLocationService()
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

    // MARK: - Setup

    private func wireLocationService() {
        locationService.onResolved = { [weak self] resolved in
            guard let self else { return }
            // Ignore a late fix if the user has since switched back to a postal
            // code, so a stale CoreLocation result can't overwrite a newer choice.
            guard self.locationSource == .coreLocation else {
                Log.location.info("Ignoring stale location fix; source is now postal code")
                return
            }
            self.settings.location = resolved
            self.location = resolved
            self.countryInput = resolved.country
            self.locationError = nil
            self.tick()
        }
        locationService.onError = { [weak self] message in
            self?.locationError = message
        }
        // Mirror auth status into our published copy.
        locationService.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.locationAuthStatus = self?.locationService.authorizationStatus ?? .notDetermined
            }
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func startTimer() {
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

    // MARK: - Scheduler construction

    /// Build a Scheduler from current settings, or nil if we can't schedule yet
    /// (sun mode requires a resolved location; fixed mode never does).
    private func buildScheduler() -> Scheduler? {
        switch scheduleMode {
        case .sun:
            guard let location else { return nil }
            return Scheduler(config: .sun(latitude: location.latitude,
                                          longitude: location.longitude,
                                          darkOffsetMinutes: darkOffsetMinutes,
                                          lightOffsetMinutes: lightOffsetMinutes),
                             timeZone: timeZone)
        case .fixed:
            return Scheduler(config: .fixed(darkMinutes: fixedDarkMinutes,
                                            lightMinutes: fixedLightMinutes),
                             timeZone: timeZone)
        }
    }

    // MARK: - The evaluation tick

    /// Recompute desired appearance from the current time & settings, run it
    /// through the pure state machine, and apply the result.
    func tick(now: Date = Date()) {
        currentMode = appearance.currentMode()
        updateSunDisplay(now: now)

        guard let scheduler = buildScheduler() else {
            // No schedule available (sun mode w/o location): reflect, don't
            // enforce — but still expire a due override so it can't linger.
            if let ov = override, !ov.isActive(at: now) {
                override = nil
                settings.override = nil
            }
            scheduledMode = currentMode
            nextTransition = nil
            updateGlance()
            return
        }

        scheduledMode = scheduler.desiredMode(at: now)
        let next = scheduler.nextTransition(after: now)
        nextTransition = next
        let boundary = next?.date ?? now.addingTimeInterval(12 * 3600)

        let decision = EnforcementEngine.decide(now: now,
                                                currentMode: currentMode,
                                                scheduledMode: scheduledMode,
                                                lastEnforced: lastEnforced,
                                                override: override,
                                                nextBoundary: boundary)

        // Persist any override change.
        if decision.override != override {
            override = decision.override
            settings.override = decision.override
            if let ov = decision.override, ov.reason == .manual {
                Log.scheduler.info("Manual divergence detected → override until \(ov.until, privacy: .public)")
            }
        }
        if let mode = decision.enforce {
            let outcome = appearance.enforce(desired: mode)
            switch outcome {
            case .applied(let applied):
                permissionBlocked = false
                lastEnforced = applied
                if notificationsEnabled { notifications.postSwitch(to: applied) }
            case .unchanged(let unchangedMode):
                permissionBlocked = false
                lastEnforced = unchangedMode
            case .failedPermission:
                // We did NOT change the appearance. Keep `lastEnforced` equal to
                // the live appearance so the next tick retries instead of
                // mistaking the unchanged appearance for a manual override.
                permissionBlocked = true
                lastEnforced = appearance.currentMode()
            case .failed:
                permissionBlocked = false
                lastEnforced = appearance.currentMode()
            }
        } else {
            // Suspended (paused) or a detected manual divergence: accept the
            // user's current appearance as the new baseline.
            lastEnforced = decision.lastEnforced
        }

        currentMode = appearance.currentMode()
        // Keep Night Shift tied to the appearance actually in effect (so a failed
        // or permission-blocked switch never leaves the display warm in Light).
        if decision.enforce != nil {
            syncNightShift(active: currentMode.isDark)
        }
        updateGlance()
    }

    /// Update the sunrise/sunset values shown in the popover (sun mode only).
    private func updateSunDisplay(now: Date) {
        guard scheduleMode == .sun, let location else {
            sunrise = .alwaysDown
            sunset = .alwaysDown
            return
        }
        let times = SunCalculator.sunTimes(latitude: location.latitude,
                                           longitude: location.longitude,
                                           date: now, timeZone: timeZone)
        sunrise = times.sunrise
        sunset = times.sunset
    }

    private func syncNightShift(active: Bool) {
        guard nightShiftEnabled, nightShift.isAvailable else { return }
        if lastNightShiftActive == active { return }
        if nightShift.setActive(active) {
            lastNightShiftActive = active
        }
    }

    // MARK: - Glance (menu-bar readout)

    private func updateGlance() {
        glanceText = glanceSummary
    }

    /// One-line summary for the menu bar's help/accessibility label.
    var glanceSummary: String {
        if let override, override.isActive(at: Date()) {
            return "Paused — resumes \(shortDateTime(override.until))"
        }
        if let next = nextTransition {
            return "Next: \(next.mode.label) at \(shortDateTime(next.date))"
        }
        return "Dark Mode Scheduler"
    }

    /// Human-readable override description for the popover.
    var overrideDescription: String? {
        guard let override, override.isActive(at: Date()) else { return nil }
        let resumes = shortDateTime(override.until)
        switch override.reason {
        case .manual:              return "Manual override — resumes \(resumes)"
        case .pausedDuration:      return "Paused — resumes \(resumes)"
        case .pausedUntilBoundary: return "Paused until next transition — resumes \(resumes)"
        }
    }

    // MARK: - Manual override / pause actions (feature 1)

    func pauseForOneHour(now: Date = Date()) {
        setOverride(Override(reason: .pausedDuration, until: now.addingTimeInterval(3600)))
    }

    func pauseUntilNextBoundary(now: Date = Date()) {
        let boundary = buildScheduler()?.nextTransition(after: now)?.date
            ?? now.addingTimeInterval(12 * 3600)
        setOverride(Override(reason: .pausedUntilBoundary, until: boundary))
    }

    func resumeNow() {
        setOverride(nil)
    }

    private func setOverride(_ newValue: Override?) {
        override = newValue
        settings.override = newValue
        tick()
    }

    // MARK: - Mode & tuning setters (feature 2, 3)

    func setScheduleMode(_ mode: ScheduleMode) {
        scheduleMode = mode
        settings.scheduleMode = mode
        tick()
    }

    func setFixedDarkMinutes(_ minutes: Int) {
        settings.fixedDarkMinutes = minutes
        fixedDarkMinutes = settings.fixedDarkMinutes
        tick()
    }

    func setFixedLightMinutes(_ minutes: Int) {
        settings.fixedLightMinutes = minutes
        fixedLightMinutes = settings.fixedLightMinutes
        tick()
    }

    func setDarkOffset(_ minutes: Int) {
        settings.darkOffsetMinutes = minutes
        darkOffsetMinutes = settings.darkOffsetMinutes
        tick()
    }

    func setLightOffset(_ minutes: Int) {
        settings.lightOffsetMinutes = minutes
        lightOffsetMinutes = settings.lightOffsetMinutes
        tick()
    }

    // MARK: - Location: postal code (features 5) & CoreLocation (feature 4)

    func saveLocation() {
        let code = zipInput.trimmingCharacters(in: .whitespaces)
        let cc = countryInput.trimmingCharacters(in: .whitespaces).uppercased()
        guard GeocodeService.isPlausiblePostal(code, country: cc) else {
            geocodeError = (cc == "US" ? GeocodeError.invalidZip : GeocodeError.invalidPostal).errorDescription
            return
        }
        // No re-fetch when nothing changed.
        if let existing = location, existing.source == .zip,
           existing.zip == code, existing.country.uppercased() == cc {
            geocodeError = nil
            tick()
            return
        }

        geocodeError = nil
        isResolving = true
        Task {
            defer { isResolving = false }
            do {
                let resolved = try await geocoder.resolve(postal: code, country: cc)
                settings.location = resolved
                location = resolved
                settings.locationSource = .zip
                locationSource = .zip
                geocodeError = nil
                tick()
            } catch let error as GeocodeError {
                geocodeError = error.errorDescription
            } catch {
                geocodeError = GeocodeError.badResponse.errorDescription
            }
        }
    }

    func setLocationSource(_ source: LocationSource) {
        locationSource = source
        settings.locationSource = source
        if source == .coreLocation {
            useMyLocation()
        } else {
            locationError = nil
            tick()
        }
    }

    func useMyLocation() {
        locationError = nil
        locationService.requestLocation()
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notifications (feature 6)

    func setNotificationsEnabled(_ enabled: Bool) {
        if enabled {
            notifications.requestAuthorization { [weak self] granted in
                guard let self else { return }
                // If denied, the toggle simply reflects the real (off) state.
                self.notificationsEnabled = granted
                self.settings.notificationsEnabled = granted
            }
        } else {
            notificationsEnabled = false
            settings.notificationsEnabled = false
        }
    }

    // MARK: - Night Shift (feature 8)

    func setNightShiftEnabled(_ enabled: Bool) {
        nightShiftEnabled = enabled
        settings.nightShiftEnabled = enabled
        if enabled {
            lastNightShiftActive = nil
            syncNightShift(active: currentMode.isDark)
        } else {
            // Only undo warmth WE turned on; never disable a Night Shift the
            // user configured themselves (their own schedule) but we never touched.
            if nightShift.isAvailable, lastNightShiftActive == true {
                nightShift.setActive(false)
            }
            lastNightShiftActive = nil
        }
    }

    // MARK: - Launch at login (v1, unchanged)

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

    // MARK: - Formatting helpers

    func formatted(_ event: SunEvent) -> String {
        switch event {
        case .time(let date):
            return shortTime(date)
        case .alwaysUp: return "No sunset (polar day)"
        case .alwaysDown: return "No sunrise (polar night)"
        }
    }

    func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// "8:31 PM" if today, otherwise "Mon 8:31 AM".
    func shortDateTime(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = cal.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    /// Format minutes-since-midnight as a clock string (for fixed-mode UI).
    func clockString(minutes: Int) -> String {
        let h = (minutes / 60) % 24
        let m = minutes % 60
        var comps = DateComponents()
        comps.hour = h; comps.minute = m
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let date = cal.date(from: comps) ?? Date()
        return shortTime(date)
    }
}
