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

    private enum NightShiftSyncResult: Equatable {
        case noChange
        case changed
        case reconciledUnknown
        case failed
        case unverified

        var completesPendingCleanup: Bool {
            switch self {
            case .noChange, .changed, .reconciledUnknown: return true
            case .failed, .unverified: return false
            }
        }
    }

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
    @Published private(set) var scheduledPhase: SchedulePhase = .day
    @Published private(set) var currentMode: AppearanceMode = .light
    @Published private(set) var nextTransition: Transition?
    @Published private(set) var permissionBlocked = false

    // MARK: Mode + tuning
    @Published var scheduleMode: ScheduleMode = .sun
    @Published var fixedNighttimeMinutes: Int = 20 * 60
    @Published var fixedDaytimeMinutes: Int = 7 * 60
    @Published var nighttimeOffsetMinutes: Int = 0
    @Published var daytimeOffsetMinutes: Int = 0

    // MARK: Overrides / pause
    @Published private(set) var override: Override?

    // MARK: Switch early (bring the next scheduled change forward)
    @Published private(set) var earlySwitchError: String?

    // MARK: Feature toggles
    @Published var notificationsEnabled = false
    @Published var darkAppearanceEnabled = true
    @Published var nightShiftEnabled = false
    @Published private(set) var nightShiftAvailable = false
    @Published private(set) var nightShiftError: String?

    // MARK: Launch at login
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    // MARK: Glance
    @Published private(set) var glanceText = "Dark Mode Scheduler"

    // Derived helpers used by the UI.
    var scheduledNight: Bool { displayedPhase.isNight }
    var scheduleMatches: Bool {
        let appearanceMatches = !darkAppearanceEnabled || currentMode == scheduledPhase.appearance
        let nightShiftMatches = !nightShiftEnabled || !nightShiftAvailable
            || lastNightShiftActive == scheduledPhase.isNight
        return appearanceMatches && nightShiftMatches
    }
    var hasAvailableEffects: Bool {
        darkAppearanceEnabled || (nightShiftEnabled && nightShiftAvailable)
    }
    var selectedEffects: ScheduleEffects {
        ScheduleEffects(darkAppearance: darkAppearanceEnabled, nightShift: nightShiftEnabled)
    }
    var isOverridden: Bool { override != nil }
    /// True while a "Switch early" override is holding the brought-forward mode.
    var isEarlySwitch: Bool { override?.reason == .earlySwitch }

    // MARK: Collaborators
    private let settings = SettingsStore()
    private let geocoder = GeocodeService()
    private let appearance = AppearanceController()
    private let notifications = NotificationService()
    private let nightShift: NightShiftControlling = CoreBrightnessNightShift()
    let locationService = LocationService()
    /// Read live (not captured once at launch) so scheduling follows the
    /// device's current time zone even if it changes while the app is running.
    private var timeZone: TimeZone { .current }

    private var timer: Timer?              // 60s safety-net poll
    private var transitionTimer: Timer?    // one-shot, fires right at the next boundary
    private var wakeObserver: NSObjectProtocol?
    private var timeChangeObservers: [NSObjectProtocol] = []

    /// The mode the app believes it last put in effect (or accepted). Seeds the
    /// manual-divergence detection so the first tick never false-triggers.
    private var lastAppearanceBaseline: AppearanceMode = .light
    /// Dedup for Night Shift calls.
    private var lastNightShiftActive: Bool?
    private var nightShiftOwnedActive = false
    private var pendingNightShiftDeactivation = false

    init() {
        // Load persisted settings into published mirrors.
        location = settings.location
        scheduleMode = settings.scheduleMode
        fixedNighttimeMinutes = settings.fixedNighttimeMinutes
        fixedDaytimeMinutes = settings.fixedDaytimeMinutes
        nighttimeOffsetMinutes = settings.nighttimeOffsetMinutes
        daytimeOffsetMinutes = settings.daytimeOffsetMinutes
        locationSource = settings.locationSource
        notificationsEnabled = settings.notificationsEnabled
        darkAppearanceEnabled = settings.darkAppearanceEnabled
        nightShiftEnabled = settings.nightShiftEnabled
        nightShiftOwnedActive = settings.nightShiftOwnedActive
        pendingNightShiftDeactivation = settings.nightShiftCleanupPending
        if nightShiftEnabled, pendingNightShiftDeactivation {
            pendingNightShiftDeactivation = false
            settings.nightShiftCleanupPending = false
        }
        override = settings.override
        // A "Test switch" preview is momentary — never let it survive a relaunch.
        // (Manual/pause overrides still persist across launches, as before.)
        if override?.reason == .preview {
            override = nil
            settings.override = nil
        }
        nightShiftAvailable = nightShift.isAvailable

        zipInput = location?.source == .zip ? (location?.zip ?? "") : ""
        countryInput = location?.country ?? "US"

        // Seed the divergence baseline to the live appearance.
        lastAppearanceBaseline = appearance.currentMode()
        locationAuthStatus = locationService.authorizationStatus

        wireLocationService()
        refreshLaunchAtLoginStatus()
        startTimer()
        observeWake()
        observeTimeChanges()
        tick()  // evaluate & enforce immediately on launch
    }

    deinit {
        timer?.invalidate()
        transitionTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        timeChangeObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
            self.scheduleInputsDidChange()
        }
        locationService.onError = { [weak self] message in
            self?.locationError = message
        }
        locationService.onAuthorizationGranted = { [weak self] in
            guard let self else { return }
            // Access was just granted (prompt approved, or enabled later in
            // System Settings). If the user still wants My Location and we don't
            // have a fix yet, fetch one automatically instead of making them
            // click again.
            guard self.locationSource == .coreLocation,
                  self.location?.source != .coreLocation else { return }
            Log.location.info("Access granted; auto-fetching location")
            self.locationError = nil
            self.locationService.requestLocation()
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

    /// (Re)arm a one-shot timer to fire right at the next transition, so the
    /// switch lands on time instead of waiting for the next 60s poll. Re-armed on
    /// every tick (and thus on launch, wake, and settings changes); the periodic
    /// timer remains the safety net for drift, sleep/wake, and clock changes.
    private func scheduleEventTimer(for next: Transition?, override: Override?, now: Date) {
        transitionTimer?.invalidate()
        transitionTimer = nil
        let dates = [next?.date, override?.isActive(at: now) == true ? override?.until : nil]
            .compactMap { $0 }
        guard let delay = Scheduler.fireDelay(untilNextOf: dates, now: now) else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                Log.scheduler.info("Scheduled boundary or pause expiry reached; re-evaluating")
                self?.tick()
            }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        transitionTimer = t
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.scheduler.info("System woke; re-evaluating schedule")
                self?.lastNightShiftActive = nil
                self?.tick()
            }
        }
    }

    /// Re-evaluate immediately when the system clock or time zone changes (NTP
    /// correction, manual clock change, or travelling across zones) instead of
    /// waiting up to a minute for the next periodic poll. `tick()` reads the live
    /// time and time zone and re-arms the boundary timer for the new schedule.
    private func observeTimeChanges() {
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    Log.scheduler.info("System clock/time zone changed; re-evaluating schedule")
                    self?.retargetBoundaryOverride(now: Date(), cancelEarlySwitch: false)
                    self?.lastNightShiftActive = nil
                    self?.tick()
                }
            }
            timeChangeObservers.append(observer)
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
                                          nighttimeOffsetMinutes: nighttimeOffsetMinutes,
                                          daytimeOffsetMinutes: daytimeOffsetMinutes),
                             timeZone: timeZone)
        case .fixed:
            return Scheduler(config: .fixed(nighttimeMinutes: fixedNighttimeMinutes,
                                            daytimeMinutes: fixedDaytimeMinutes),
                             timeZone: timeZone)
        }
    }

    /// Retarget boundary-relative overrides after a schedule or time-zone edit.
    /// One-hour pauses retain their duration. Schedule edits cancel an early
    /// switch because its brought-forward phase may no longer be the next one.
    private func retargetBoundaryOverride(now: Date, cancelEarlySwitch: Bool) {
        guard let current = override, current.isActive(at: now) else { return }
        if current.reason == .earlySwitch, cancelEarlySwitch {
            override = nil
            settings.override = nil
            return
        }
        guard current.reason == .manual
                || current.reason == .pausedUntilBoundary
                || current.reason == .earlySwitch,
              let boundary = buildScheduler()?.nextTransition(after: now)?.date
        else { return }
        let retargeted = Override(reason: current.reason, until: boundary)
        override = retargeted
        settings.override = retargeted
    }

    private func scheduleInputsDidChange(now: Date = Date()) {
        retargetBoundaryOverride(now: now, cancelEarlySwitch: true)
        lastNightShiftActive = nil
        tick(now: now)
    }

    // MARK: - The evaluation tick

    /// Recompute the day/night phase, then independently reconcile each selected
    /// effect through the pure state machine.
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
            scheduledPhase = .day
            nextTransition = nil
            scheduleEventTimer(for: nil, override: override, now: now)
            if pendingNightShiftDeactivation {
                let result = syncNightShift(desired: false)
                if result.completesPendingCleanup {
                    pendingNightShiftDeactivation = false
                    settings.nightShiftCleanupPending = false
                }
            }
            updateGlance()
            return
        }

        scheduledPhase = scheduler.desiredPhase(at: now)
        let next = scheduler.nextTransition(after: now)
        nextTransition = next
        scheduleEventTimer(for: next, override: override, now: now)
        let boundary = next?.date ?? now.addingTimeInterval(12 * 3600)

        let decision = EnforcementEngine.decide(now: now,
                                                phase: scheduledPhase,
                                                effects: selectedEffects,
                                                nightShiftAvailable: nightShiftAvailable,
                                                currentAppearance: currentMode,
                                                lastAppearanceBaseline: lastAppearanceBaseline,
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
        var mutatedEffects = ScheduleEffects(darkAppearance: false, nightShift: false)
        if let mode = decision.appearance {
            let outcome = appearance.enforce(desired: mode)
            switch outcome {
            case .applied(let applied):
                permissionBlocked = false
                lastAppearanceBaseline = applied
                mutatedEffects.darkAppearance = true
            case .unchanged(let unchangedMode):
                permissionBlocked = false
                lastAppearanceBaseline = unchangedMode
            case .failedPermission:
                // We did NOT change the appearance. Keep the baseline equal to
                // the live appearance so the next tick retries instead of
                // mistaking the unchanged appearance for a manual override.
                permissionBlocked = true
                lastAppearanceBaseline = appearance.currentMode()
            case .failed:
                permissionBlocked = false
                lastAppearanceBaseline = appearance.currentMode()
            }
        } else {
            // No appearance instruction: suspended, manually overridden, or
            // Dark appearance is not selected. Never prompt for Automation.
            permissionBlocked = false
            lastAppearanceBaseline = decision.lastAppearanceBaseline
        }

        let isNightShiftCleanup = pendingNightShiftDeactivation
        let desiredNightShift = isNightShiftCleanup ? false : decision.nightShift
        let nightShiftResult = syncNightShift(desired: desiredNightShift)
        if nightShiftResult == .changed, !isNightShiftCleanup {
            mutatedEffects.nightShift = true
        }
        if isNightShiftCleanup,
           nightShiftResult.completesPendingCleanup {
            pendingNightShiftDeactivation = false
            settings.nightShiftCleanupPending = false
        }
        currentMode = appearance.currentMode()
        if !mutatedEffects.isEmpty, notificationsEnabled {
            notifications.postTransition(to: scheduledPhase, effects: mutatedEffects)
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

    @discardableResult
    private func syncNightShift(desired: Bool?) -> NightShiftSyncResult {
        guard desired != nil else { return .noChange }
        guard nightShift.isAvailable else { return .unverified }
        let live = nightShift.activeState
        if let live { lastNightShiftActive = live }
        let plan = NightShiftMutationPlanner.plan(
            desired: desired, live: live, lastApplied: lastNightShiftActive
        )
        guard let mutation = plan.mutation else {
            if desired == false {
                nightShiftOwnedActive = false
                settings.nightShiftOwnedActive = false
            }
            nightShiftError = nil
            return .noChange
        }
        guard nightShift.setActive(mutation) else {
            nightShiftError = "Night Shift couldn't be changed. The app will retry."
            return .failed
        }
        lastNightShiftActive = mutation
        nightShiftOwnedActive = NightShiftOwnershipPolicy.ownershipAfterSuccessfulMutation(
            previous: nightShiftOwnedActive,
            mutation: mutation,
            isKnownChange: plan.isKnownChange
        )
        settings.nightShiftOwnedActive = nightShiftOwnedActive
        nightShiftError = nil
        return plan.isKnownChange ? .changed : .reconciledUnknown
    }

    // MARK: - Glance (menu-bar readout)

    private func updateGlance() {
        glanceText = glanceSummary
    }

    /// One-line summary for the menu bar's help/accessibility label.
    var glanceSummary: String {
        if let override, override.isActive(at: Date()) {
            switch override.reason {
            case .earlySwitch:
                return "\(displayedPhase.label) early — rejoins \(shortDateTime(override.until))"
            case .preview:
                return "Previewing \(currentMode.label) — Back to schedule"
            default:
                return "Paused — resumes \(shortDateTime(override.until))"
            }
        }
        if let next = nextTransition {
            return "Next: \(next.phase.label.lowercased()) at \(shortDateTime(next.date))"
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
        case .preview:             return "Previewing \(currentMode.label) (test switch)"
        case .earlySwitch:         return "\(displayedPhase.label) early — rejoins schedule \(resumes)"
        }
    }

    var displayedPhase: SchedulePhase {
        isEarlySwitch ? earlySwitchTarget : scheduledPhase
    }

    /// The phase "Switch early" would bring forward.
    var earlySwitchTarget: SchedulePhase {
        nextTransition?.phase ?? (scheduledPhase == .night ? .day : .night)
    }

    // MARK: - Switch early (bring the next scheduled change forward)

    /// Bring the upcoming phase's selected effects forward to now. Appearance
    /// Automation is used only when Dark appearance is selected. This registers
    /// an `.earlySwitch` override until that boundary, so the scheduler
    /// SUSPENDS and won't snap back; when the boundary arrives the schedule would
    /// have switched to this mode anyway, so it rejoins seamlessly. "Back to
    /// schedule" (`resumeNow`) undoes it early. No notification — that's for real
    /// scheduled switches. Surfaces the `EnforceOutcome` via `earlySwitchError` /
    /// `permissionBlocked`.
    func switchToNextModeEarly(now: Date = Date()) {
        earlySwitchError = nil
        let target = earlySwitchTarget
        // Hold until the schedule catches up (the next boundary); fall back to a
        // 12h window if there's no upcoming transition (e.g. sun mode w/o location).
        let boundary = nextTransition?.date ?? now.addingTimeInterval(12 * 3600)
        guard hasAvailableEffects else {
            earlySwitchError = "Select an available nighttime effect first."
            updateGlance()
            return
        }

        var failed = false
        if darkAppearanceEnabled {
            switch appearance.enforce(desired: target.appearance) {
            case .applied(let applied), .unchanged(let applied):
                permissionBlocked = false
                lastAppearanceBaseline = applied
            case .failedPermission:
                permissionBlocked = true
                failed = true
            case .failed(let code):
                permissionBlocked = false
                earlySwitchError = "Couldn't switch Dark appearance (error \(code)). Try again."
                failed = true
            }
        } else {
            permissionBlocked = false
            lastAppearanceBaseline = currentMode
        }
        if nightShiftEnabled, nightShiftAvailable {
            let live = nightShift.activeState
            if let live { lastNightShiftActive = live }
            let plan = NightShiftMutationPlanner.plan(
                desired: target.isNight, live: live,
                lastApplied: lastNightShiftActive
            )
            if plan.mutation == nil, !target.isNight {
                nightShiftOwnedActive = false
                settings.nightShiftOwnedActive = false
            }
            if let mutation = plan.mutation {
                if nightShift.setActive(mutation) {
                    lastNightShiftActive = mutation
                    nightShiftOwnedActive = NightShiftOwnershipPolicy.ownershipAfterSuccessfulMutation(
                        previous: nightShiftOwnedActive,
                        mutation: mutation,
                        isKnownChange: plan.isKnownChange
                    )
                    settings.nightShiftOwnedActive = nightShiftOwnedActive
                    nightShiftError = nil
                } else {
                    earlySwitchError = "Night Shift couldn't be changed. Try again."
                    nightShiftError = "Night Shift couldn't be changed. The app will retry."
                    failed = true
                }
            }
        }

        if !failed {
            let ov = Override(reason: .earlySwitch, until: boundary)
            override = ov
            settings.override = ov
        } else {
            // Reconcile immediately so a partially applied early switch does not
            // linger outside the schedule.
            tick(now: now)
        }
        currentMode = appearance.currentMode()
        updateGlance()
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
        // Any override change (pause, resume, "Back to schedule") ends the
        // current action, so a stale error should not linger under the UI.
        earlySwitchError = nil
        override = newValue
        settings.override = newValue
        if newValue == nil { lastNightShiftActive = nil }
        tick()
    }

    // MARK: - Mode & tuning setters (feature 2, 3)

    func setScheduleMode(_ mode: ScheduleMode) {
        scheduleMode = mode
        settings.scheduleMode = mode
        scheduleInputsDidChange()
    }

    func setFixedNighttimeMinutes(_ minutes: Int) {
        settings.fixedNighttimeMinutes = minutes
        fixedNighttimeMinutes = settings.fixedNighttimeMinutes
        scheduleInputsDidChange()
    }

    func setFixedDaytimeMinutes(_ minutes: Int) {
        settings.fixedDaytimeMinutes = minutes
        fixedDaytimeMinutes = settings.fixedDaytimeMinutes
        scheduleInputsDidChange()
    }

    func setNighttimeOffset(_ minutes: Int) {
        settings.nighttimeOffsetMinutes = minutes
        nighttimeOffsetMinutes = settings.nighttimeOffsetMinutes
        scheduleInputsDidChange()
    }

    func setDaytimeOffset(_ minutes: Int) {
        settings.daytimeOffsetMinutes = minutes
        daytimeOffsetMinutes = settings.daytimeOffsetMinutes
        scheduleInputsDidChange()
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
                scheduleInputsDidChange()
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

    // MARK: - Scheduled effects

    func setDarkAppearanceEnabled(_ enabled: Bool) {
        darkAppearanceEnabled = enabled
        settings.darkAppearanceEnabled = enabled
        // Changing selection is an explicit user action, not a manual
        // divergence. Disabling leaves the current appearance exactly as-is.
        lastAppearanceBaseline = appearance.currentMode()
        if !enabled {
            permissionBlocked = false
            if override?.reason == .manual {
                override = nil
                settings.override = nil
            }
        }
        tick()
    }

    func setNightShiftEnabled(_ enabled: Bool) {
        nightShiftEnabled = enabled
        settings.nightShiftEnabled = enabled
        if enabled {
            pendingNightShiftDeactivation = false
            settings.nightShiftCleanupPending = false
            nightShiftError = nil
            lastNightShiftActive = nil
            tick()
        } else {
            // Only undo warmth WE turned on; never disable a Night Shift the
            // user configured themselves (their own schedule) but we never touched.
            pendingNightShiftDeactivation = NightShiftOwnershipPolicy
                .needsCleanupWhenDisabled(ownedActive: nightShiftOwnedActive)
            settings.nightShiftCleanupPending = pendingNightShiftDeactivation
            if !pendingNightShiftDeactivation {
                lastNightShiftActive = nil
                nightShiftError = nil
            }
            tick()
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
