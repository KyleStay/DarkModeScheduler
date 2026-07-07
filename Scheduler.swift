import Foundation

// =============================================================================
// Scheduler.swift — the PURE, GUI-free scheduling & enforcement core.
//
// Everything in this file is plain Foundation: no AppKit, no SwiftUI, no
// UserDefaults, no I/O. That is deliberate — it lets SunCalculatorTests.swift
// unit-test the offset math, fixed-schedule boundaries, override expiry, and
// next-transition computation without a GUI or any permissions.
//
// Contents:
//   • AppearanceMode      — Light / Dark (shared by the whole app).
//   • ScheduleMode        — sun-based vs. fixed-time scheduling.
//   • Transition          — one scheduled appearance change (date + target).
//   • Scheduler           — unified sun/fixed schedule: desiredMode +
//                           nextTransition, computed from a ±day window of
//                           Transitions so both modes share identical logic.
//   • Override            — a single representation of "enforcement suspended
//                           until `until`", covering manual pause, timed pause,
//                           and detected manual divergence.
//   • EnforcementEngine   — the pure state-machine decision (the crux).
// =============================================================================

// MARK: - Appearance

enum AppearanceMode: String, Equatable, Codable {
    case light
    case dark

    var isDark: Bool { self == .dark }
    var label: String { self == .dark ? "Dark" : "Light" }
}

// MARK: - Schedule mode

enum ScheduleMode: String, Equatable, Codable {
    case sun     // Dark at sunset(+offset), Light at sunrise(+offset).
    case fixed   // Dark / Light at explicit clock times.

    var label: String { self == .sun ? "Sun-based" : "Fixed times" }
}

// MARK: - Transition

/// One scheduled appearance change: at `date`, the appearance should become `mode`.
struct Transition: Equatable {
    let date: Date
    let mode: AppearanceMode
}

// MARK: - Scheduler

/// Unifies sun-based and fixed-time scheduling behind two questions:
///   • what mode *should* be in effect at a given instant, and
///   • when is the next boundary (transition) after a given instant.
///
/// Both are answered from a single sorted list of `Transition`s spanning a few
/// days around the query instant, so the two modes share identical downstream
/// logic (idempotency, override expiry, glance, wake handling).
struct Scheduler {

    enum Config: Equatable {
        /// Sun-based. Offsets are minutes applied to the NOAA event:
        /// `darkOffset` shifts sunset (negative = earlier), `lightOffset` shifts sunrise.
        case sun(latitude: Double, longitude: Double, darkOffsetMinutes: Int, lightOffsetMinutes: Int)
        /// Fixed clock times, expressed as minutes since local midnight.
        case fixed(darkMinutes: Int, lightMinutes: Int)
    }

    let config: Config
    let timeZone: TimeZone

    init(config: Config, timeZone: TimeZone) {
        self.config = config
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// Local midnight for the calendar day that contains `date`.
    private func midnight(of date: Date) -> Date? {
        let cal = calendar
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        return cal.date(from: comps)
    }

    /// Transitions for a single calendar day (identified by its local midnight),
    /// in chronological order. May be empty on polar days in sun mode.
    private func transitions(forDayStartingAt dayMidnight: Date) -> [Transition] {
        switch config {
        case let .sun(lat, lon, darkOff, lightOff):
            let times = SunCalculator.sunTimes(latitude: lat, longitude: lon,
                                               date: dayMidnight, timeZone: timeZone)
            var out: [Transition] = []
            if case .time(let sunrise) = times.sunrise {
                out.append(Transition(date: sunrise.addingTimeInterval(Double(lightOff) * 60),
                                      mode: .light))
            }
            if case .time(let sunset) = times.sunset {
                out.append(Transition(date: sunset.addingTimeInterval(Double(darkOff) * 60),
                                      mode: .dark))
            }
            return out.sorted { $0.date < $1.date }

        case let .fixed(darkMinutes, lightMinutes):
            return [Transition(date: fixedTime(on: dayMidnight, minutes: lightMinutes), mode: .light),
                    Transition(date: fixedTime(on: dayMidnight, minutes: darkMinutes), mode: .dark)]
                .sorted(by: Self.chronological)
        }
    }

    /// Deterministic ordering: by date, and on an exact tie put Dark before
    /// Light. That makes a degenerate equal-times config (dark == light) resolve
    /// to Light for `desiredMode` (the last transition ≤ now), matching the
    /// "empty dark window ⇒ always light" fallback, instead of depending on an
    /// unstable sort.
    private static func chronological(_ a: Transition, _ b: Transition) -> Bool {
        if a.date != b.date { return a.date < b.date }
        return a.mode == .dark && b.mode == .light
    }

    /// The wall-clock time-of-day (`minutes` since midnight) on the given day,
    /// resolved DST-aware via the calendar. Adding raw seconds to midnight would
    /// drift by an hour on spring-forward / fall-back days (e.g. a fixed 07:00
    /// would fire at 08:00 after spring-forward); building from components keeps
    /// it anchored to 07:00 wall-clock.
    private func fixedTime(on dayMidnight: Date, minutes: Int) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60,
                      second: 0, of: dayMidnight)
            ?? dayMidnight.addingTimeInterval(Double(minutes) * 60)
    }

    /// Sorted transitions across `[day-1 … day+2]` relative to `now`. This window
    /// is wide enough that there is always at least one transition before `now`
    /// and one after it for any non-polar location.
    func transitions(around now: Date) -> [Transition] {
        guard let today = midnight(of: now) else { return [] }
        let cal = calendar
        var all: [Transition] = []
        for offset in -1...2 {
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            all.append(contentsOf: transitions(forDayStartingAt: dayStart))
        }
        return all.sorted(by: Self.chronological)
    }

    /// The appearance that *should* be in effect at `now`.
    ///
    /// = the mode of the most recent transition at/before `now`. Falls back to a
    /// polar-safe rule when the window has no transition before `now` (only
    /// reachable at extreme latitudes, never for US locations).
    func desiredMode(at now: Date) -> AppearanceMode {
        let events = transitions(around: now)
        if let last = events.last(where: { $0.date <= now }) {
            return last.mode
        }
        // No transition before `now` in the window → polar fallback.
        return polarFallbackMode(at: now)
    }

    /// The first transition strictly after `now`, if any.
    func nextTransition(after now: Date) -> Transition? {
        transitions(around: now).first(where: { $0.date > now })
    }

    /// How long from `now` until enforcement should re-run to apply `transition`.
    ///
    /// Used to arm a one-shot timer that fires right at the boundary (so a switch
    /// lands on time instead of waiting for the next periodic poll). A 1-second
    /// cushion is added so the schedule has advanced past the boundary when we
    /// re-evaluate. Returns nil when there's no upcoming transition, or it's
    /// already due/past (the caller enforces immediately in that case).
    static func fireDelay(until transition: Transition?, now: Date) -> TimeInterval? {
        guard let transition else { return nil }
        let delay = transition.date.timeIntervalSince(now) + 1
        return delay > 0 ? delay : nil
    }

    /// Polar / degenerate fallback: use today's raw NOAA geometry (sun mode) or a
    /// direct clock comparison (fixed mode) to pick a mode without transitions.
    private func polarFallbackMode(at now: Date) -> AppearanceMode {
        switch config {
        case let .sun(lat, lon, _, _):
            let times = SunCalculator.sunTimes(latitude: lat, longitude: lon,
                                               date: now, timeZone: timeZone)
            switch times.sunrise {
            case .alwaysUp:   return .light   // sun never sets → day
            case .alwaysDown: return .dark    // sun never rises → night
            case .time:       return .light   // unreachable given caller; safe default
            }
        case let .fixed(darkMinutes, lightMinutes):
            guard let mid = midnight(of: now) else { return .light }
            let minutes = Int(now.timeIntervalSince(mid) / 60)
            // Dark window = [darkMinutes, lightMinutes) treating the day cyclically.
            if darkMinutes <= lightMinutes {
                return (minutes >= darkMinutes && minutes < lightMinutes) ? .dark : .light
            } else {
                return (minutes >= darkMinutes || minutes < lightMinutes) ? .dark : .light
            }
        }
    }
}

// MARK: - Override

/// A single, unified representation of "the scheduler is suspended until `until`".
///
/// The three reasons differ ONLY in what triggered them and how the UI describes
/// them; they all expire the same way (`now >= until`). This keeps the state
/// machine tiny — there is exactly one suspended state, not three.
struct Override: Codable, Equatable {
    enum Reason: String, Codable, Equatable {
        case manual              // user manually flipped appearance (detected divergence)
        case pausedDuration      // "Pause for 1 hour"
        case pausedUntilBoundary // "Pause until next sunrise/sunset"
        case preview             // legacy: on-demand appearance preview (superseded by earlySwitch)
        case earlySwitch         // user brought the next scheduled switch forward ("Switch early")

        /// Decode leniently: any raw value this build doesn't recognize (a case
        /// added by a newer build, or one later renamed/removed) maps to
        /// `.manual` — a conservative "honor the user until the next boundary"
        /// default — instead of throwing and silently discarding the whole
        /// persisted Override. Known raw values decode exactly as written.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? .manual
        }
    }

    let reason: Reason
    let until: Date

    func isActive(at now: Date) -> Bool { now < until }
}

// MARK: - Enforcement engine (the pure state machine — the crux)

/// The result of one evaluation: the override state afterwards, the mode to
/// enforce (nil when suspended), and the new `lastEnforced` baseline.
struct EnforcementDecision: Equatable {
    var override: Override?
    /// Mode to enforce this tick, or nil if enforcement is suspended.
    var enforce: AppearanceMode?
    var lastEnforced: AppearanceMode
}

/// Pure decision function shared by the live app, the self-test, and unit tests.
///
/// See the four-step state machine documented in the project notes:
///   1. EXPIRE a due override.
///   2. SUSPEND while an override is active (accept the user's current mode).
///   3. DETECT a manual divergence (live appearance ≠ what we last set) and
///      convert it into a `.manual` override until the next boundary.
///   4. ENFORCE the scheduled mode otherwise.
enum EnforcementEngine {
    static func decide(now: Date,
                       currentMode: AppearanceMode,
                       scheduledMode: AppearanceMode,
                       lastEnforced: AppearanceMode,
                       override: Override?,
                       nextBoundary: Date) -> EnforcementDecision {

        // 1. EXPIRE.
        var active = override
        if let o = active, !o.isActive(at: now) {
            active = nil
        }

        // 2. SUSPEND — an override is still in force. Accept whatever the user
        //    has set as the new baseline so we don't "correct" it later.
        if let o = active {
            return EnforcementDecision(override: o, enforce: nil, lastEnforced: currentMode)
        }

        // 3. DETECT MANUAL DIVERGENCE — the live appearance differs from the
        //    schedule AND from what we last set. Only the user could have done
        //    that, so honor it until the next natural boundary instead of
        //    snapping back on this tick.
        if currentMode != scheduledMode && currentMode != lastEnforced {
            let ov = Override(reason: .manual, until: nextBoundary)
            return EnforcementDecision(override: ov, enforce: nil, lastEnforced: currentMode)
        }

        // 4. ENFORCE the schedule (idempotently downstream).
        return EnforcementDecision(override: nil, enforce: scheduledMode, lastEnforced: scheduledMode)
    }
}
