import Foundation

// Standalone, GUI-free unit tests for `SunCalculator`.
//
// This is NOT an XCTest bundle (there is no .xcodeproj in this project). It is a
// self-contained assertion runner with an `@main` entry point: it prints each
// check, and calls `exit(1)` on the first failure so `run-tests.sh` fails loudly.
//
// Compile with:  swiftc SunCalculatorTests.swift SunCalculator.swift -o tests
//
// Authoritative reference values below come from the U.S. Naval Observatory
// (USNO) "one day" astronomical almanac API — https://aa.usno.navy.mil/data/ —
// which reports sunrise/sunset rounded to the whole minute. Every assertion
// requires our locally computed time to fall within ±2 minutes of the reference.

// MARK: - Tiny assertion harness

final class TestRunner {
    private var failures = 0
    private var checks = 0

    func check(_ condition: Bool, _ message: String) {
        checks += 1
        if condition {
            print("  ✅ \(message)")
        } else {
            failures += 1
            print("  ❌ \(message)")
        }
    }

    /// Assert an event resolves to a concrete time within `toleranceSeconds`
    /// of an expected wall-clock hour:minute in `timeZone`.
    func checkTime(_ event: SunEvent,
                   equals expected: (h: Int, m: Int),
                   onDay day: DateComponents,
                   timeZone: TimeZone,
                   toleranceSeconds: Double,
                   label: String) {
        guard case .time(let actual) = event else {
            check(false, "\(label): expected a concrete time, got \(event)")
            return
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var comps = day
        comps.hour = expected.h
        comps.minute = expected.m
        comps.second = 0
        guard let expectedDate = cal.date(from: comps) else {
            check(false, "\(label): could not build expected date")
            return
        }
        let delta = abs(actual.timeIntervalSince(expectedDate))
        let fmt = DateFormatter()
        fmt.timeZone = timeZone
        fmt.dateFormat = "HH:mm:ss"
        check(delta <= toleranceSeconds,
              "\(label): computed \(fmt.string(from: actual)) vs USNO \(String(format: "%02d:%02d", expected.h, expected.m)) (Δ \(Int(delta))s ≤ \(Int(toleranceSeconds))s)")
    }

    func finish() -> Never {
        print("\n\(checks - failures)/\(checks) checks passed.")
        if failures == 0 {
            print("ALL TESTS PASSED ✅")
            exit(0)
        } else {
            print("\(failures) TEST(S) FAILED ❌")
            exit(1)
        }
    }
}

// MARK: - Helpers

private func day(_ y: Int, _ mo: Int, _ d: Int) -> DateComponents {
    DateComponents(year: y, month: mo, day: d)
}

private func noon(_ comps: DateComponents, _ tz: TimeZone) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    var c = comps
    c.hour = 12
    return cal.date(from: c)!
}

// MARK: - Test suite

@main
struct SunCalculatorTestMain {
    static func main() {
        let t = TestRunner()
        let tolerance = 120.0  // ±2 minutes, per the correctness bar.

        // --- Reference case 1: New York City, summer solstice ---
        // USNO: Sunrise 05:25 EDT, Sunset 20:31 EDT on 2021-06-21.
        do {
            print("New York City — 2021-06-21 (40.7128, -74.0060), EDT:")
            let tz = TimeZone(identifier: "America/New_York")!
            let d = day(2021, 6, 21)
            let s = SunCalculator.sunTimes(latitude: 40.7128, longitude: -74.0060,
                                           date: noon(d, tz), timeZone: tz)
            t.checkTime(s.sunrise, equals: (5, 25), onDay: d, timeZone: tz,
                        toleranceSeconds: tolerance, label: "NYC sunrise")
            t.checkTime(s.sunset, equals: (20, 31), onDay: d, timeZone: tz,
                        toleranceSeconds: tolerance, label: "NYC sunset")
        }

        // --- Reference case 2: Los Angeles, winter solstice ---
        // USNO: Sunrise 06:55 PST, Sunset 16:48 PST on 2021-12-21.
        do {
            print("Los Angeles — 2021-12-21 (34.0522, -118.2437), PST:")
            let tz = TimeZone(identifier: "America/Los_Angeles")!
            let d = day(2021, 12, 21)
            let s = SunCalculator.sunTimes(latitude: 34.0522, longitude: -118.2437,
                                           date: noon(d, tz), timeZone: tz)
            t.checkTime(s.sunrise, equals: (6, 55), onDay: d, timeZone: tz,
                        toleranceSeconds: tolerance, label: "LA sunrise")
            t.checkTime(s.sunset, equals: (16, 48), onDay: d, timeZone: tz,
                        toleranceSeconds: tolerance, label: "LA sunset")
        }

        // --- Reference case 3: Chicago, autumnal equinox (DST in effect) ---
        // USNO: Sunrise 06:39 CDT, Sunset 18:46 CDT on 2023-09-23.
        do {
            print("Chicago — 2023-09-23 (41.8781, -87.6298), CDT:")
            let tz = TimeZone(identifier: "America/Chicago")!
            let d = day(2023, 9, 23)
            let s = SunCalculator.sunTimes(latitude: 41.8781, longitude: -87.6298,
                                           date: noon(d, tz), timeZone: tz)
            t.checkTime(s.sunrise, equals: (6, 39), onDay: d, timeZone: tz,
                        toleranceSeconds: tolerance, label: "Chicago sunrise")
            t.checkTime(s.sunset, equals: (18, 46), onDay: d, timeZone: tz,
                        toleranceSeconds: tolerance, label: "Chicago sunset")
        }

        // --- DST-awareness sanity check ---
        // The same NYC location on the winter solstice must land in EST (UTC-5),
        // so its clock times differ from the summer (EDT, UTC-4) result. This
        // guards against a hardcoded/naive offset regression.
        do {
            print("DST awareness — NYC winter vs summer offset:")
            let tz = TimeZone(identifier: "America/New_York")!
            let winter = day(2021, 12, 21)
            let s = SunCalculator.sunTimes(latitude: 40.7128, longitude: -74.0060,
                                           date: noon(winter, tz), timeZone: tz)
            // USNO: NYC 2021-12-21 sunrise 07:17 EST, sunset 16:32 EST.
            t.checkTime(s.sunrise, equals: (7, 17), onDay: winter, timeZone: tz,
                        toleranceSeconds: tolerance, label: "NYC winter sunrise (EST)")
            t.checkTime(s.sunset, equals: (16, 32), onDay: winter, timeZone: tz,
                        toleranceSeconds: tolerance, label: "NYC winter sunset (EST)")
        }

        // --- Ordering / duration sanity check ---
        do {
            print("Sanity — sunrise precedes sunset, plausible day length:")
            let tz = TimeZone(identifier: "America/Denver")!
            let d = day(2024, 3, 20)  // equinox: day length ≈ 12h
            let s = SunCalculator.sunTimes(latitude: 39.7392, longitude: -104.9903,
                                           date: noon(d, tz), timeZone: tz)
            if case .time(let sr) = s.sunrise, case .time(let ss) = s.sunset {
                t.check(sr < ss, "Denver sunrise before sunset")
                let hours = ss.timeIntervalSince(sr) / 3600.0
                t.check(hours > 11.5 && hours < 12.7,
                        "Denver equinox day length ≈ 12h (got \(String(format: "%.2f", hours))h)")
            } else {
                t.check(false, "Denver produced concrete sunrise/sunset")
            }
        }

        // --- Polar edge cases ---
        do {
            print("Polar — Utqiaġvik (Barrow), AK (71.29, -156.79):")
            let tz = TimeZone(identifier: "America/Anchorage")!
            // Deep winter → polar night (sun never rises).
            let winter = SunCalculator.sunTimes(latitude: 71.2906, longitude: -156.7886,
                                                date: noon(day(2021, 12, 21), tz), timeZone: tz)
            t.check(winter.sunrise == .alwaysDown && winter.sunset == .alwaysDown,
                    "polar night → .alwaysDown (got \(winter.sunrise))")
            // Midsummer → polar day (sun never sets).
            let summer = SunCalculator.sunTimes(latitude: 71.2906, longitude: -156.7886,
                                                date: noon(day(2021, 6, 21), tz), timeZone: tz)
            t.check(summer.sunrise == .alwaysUp && summer.sunset == .alwaysUp,
                    "polar day → .alwaysUp (got \(summer.sunrise))")
        }

        // =====================================================================
        // v2: Scheduler (offsets, fixed mode, next-transition) & state machine.
        // These are pure and GUI-free, exactly like the sun-math checks above.
        // =====================================================================

        let nyTZ = TimeZone(identifier: "America/New_York")!
        var nyCal = Calendar(identifier: .gregorian); nyCal.timeZone = nyTZ
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            nyCal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        func midnight(_ y: Int, _ mo: Int, _ d: Int) -> Date {
            nyCal.date(from: DateComponents(year: y, month: mo, day: d))!
        }

        // --- Sun-time offsets (feature 3) ---
        do {
            print("Sun offsets — NYC 2024-06-01, Dark −30m / Light +15m:")
            let base = SunCalculator.sunTimes(latitude: 40.71, longitude: -74.0,
                                              date: noon(day(2024, 6, 1), nyTZ), timeZone: nyTZ)
            let sched = Scheduler(config: .sun(latitude: 40.71, longitude: -74.0,
                                               nighttimeOffsetMinutes: -30, daytimeOffsetMinutes: 15),
                                  timeZone: nyTZ)
            let dayStart = midnight(2024, 6, 1)
            let dayEnd = midnight(2024, 6, 2)
            let onDay = sched.transitions(around: noon(day(2024, 6, 1), nyTZ))
                .filter { $0.date >= dayStart && $0.date < dayEnd }
            if case .time(let sunset) = base.sunset,
               let dark = onDay.first(where: { $0.phase == .night }) {
                let delta = sunset.timeIntervalSince(dark.date)
                t.check(abs(delta - 1800) < 30, "dark offset lands 30m before sunset (Δ \(Int(delta))s)")
            } else { t.check(false, "offset: found dark transition on day") }
            if case .time(let sunrise) = base.sunrise,
               let light = onDay.first(where: { $0.phase == .day }) {
                let delta = light.date.timeIntervalSince(sunrise)
                t.check(abs(delta - 900) < 30, "light offset lands 15m after sunrise (Δ \(Int(delta))s)")
            } else { t.check(false, "offset: found light transition on day") }
        }

        // --- Fixed-schedule boundary logic (feature 2) ---
        do {
            print("Fixed schedule — Dark 20:00 / Light 07:00:")
            let s = Scheduler(config: .fixed(nighttimeMinutes: 20 * 60, daytimeMinutes: 7 * 60), timeZone: nyTZ)
            t.check(s.desiredPhase(at: at(2024, 1, 10, 21, 0)) == .night, "21:00 → Dark")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 6, 59)) == .night, "06:59 → Dark")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 7, 1)) == .day, "07:01 → Light")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 19, 59)) == .day, "19:59 → Light")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 0, 30)) == .night, "00:30 → Dark")
        }

        // --- Degenerate fixed schedule (Dark time == Light time) is deterministic ---
        do {
            print("Fixed schedule (degenerate) — Dark == Light == 07:00:")
            let s = Scheduler(config: .fixed(nighttimeMinutes: 7 * 60, daytimeMinutes: 7 * 60), timeZone: nyTZ)
            t.check(s.desiredPhase(at: at(2024, 1, 10, 12, 0)) == .day, "equal times → Light (deterministic)")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 23, 0)) == .day, "equal times → Light late in day")
        }

        // --- Inverted fixed schedule (Dark before Light within the day) ---
        do {
            print("Fixed schedule (inverted) — Dark 09:00 / Light 18:00:")
            let s = Scheduler(config: .fixed(nighttimeMinutes: 9 * 60, daytimeMinutes: 18 * 60), timeZone: nyTZ)
            t.check(s.desiredPhase(at: at(2024, 1, 10, 12, 0)) == .night, "12:00 → Dark (between)")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 20, 0)) == .day, "20:00 → Light (after)")
            t.check(s.desiredPhase(at: at(2024, 1, 10, 6, 0)) == .day, "06:00 → Light (before)")
        }

        // --- Fixed times are DST-anchored to wall-clock, not elapsed seconds ---
        do {
            print("Fixed schedule DST anchoring — America/New_York:")
            let s = Scheduler(config: .fixed(nighttimeMinutes: 20 * 60, daytimeMinutes: 7 * 60), timeZone: nyTZ)
            // Spring-forward day (clocks jump 02:00→03:00). A raw midnight+7h would
            // land at 08:00; the fix must keep the Light transition at 07:00.
            let springNoon = at(2024, 3, 10, 12, 0)
            if let light = s.transitions(around: springNoon)
                .first(where: { nyCal.isDate($0.date, inSameDayAs: springNoon) && $0.phase == .day }) {
                let c = nyCal.dateComponents([.hour, .minute], from: light.date)
                t.check(c.hour == 7 && c.minute == 0, "spring-forward Light stays 07:00 (got \(c.hour ?? -1):\(c.minute ?? -1))")
            } else { t.check(false, "DST: found spring-forward Light transition") }
            // Fall-back day (clocks 02:00→01:00). Dark at 20:00 must stay 20:00.
            let fallNoon = at(2024, 11, 3, 12, 0)
            if let dark = s.transitions(around: fallNoon)
                .first(where: { nyCal.isDate($0.date, inSameDayAs: fallNoon) && $0.phase == .night }) {
                let c = nyCal.dateComponents([.hour, .minute], from: dark.date)
                t.check(c.hour == 20 && c.minute == 0, "fall-back Dark stays 20:00 (got \(c.hour ?? -1):\(c.minute ?? -1))")
            } else { t.check(false, "DST: found fall-back Dark transition") }
        }

        // --- Next-transition computation (both modes) ---
        do {
            print("Next transition:")
            let fixed = Scheduler(config: .fixed(nighttimeMinutes: 20 * 60, daytimeMinutes: 7 * 60), timeZone: nyTZ)
            if let next = fixed.nextTransition(after: at(2024, 1, 10, 12, 0)) {
                let comps = nyCal.dateComponents([.hour, .minute], from: next.date)
                t.check(next.phase == .night && comps.hour == 20 && comps.minute == 0,
                        "fixed: next after 12:00 is Dark@20:00")
            } else { t.check(false, "fixed: expected a next transition") }
            if let next = fixed.nextTransition(after: at(2024, 1, 10, 21, 0)) {
                let comps = nyCal.dateComponents([.hour, .minute], from: next.date)
                t.check(next.phase == .day && comps.hour == 7,
                        "fixed: next after 21:00 is Light@07:00 (next day)")
            } else { t.check(false, "fixed: expected a next transition after 21:00") }

            let sun = Scheduler(config: .sun(latitude: 40.71, longitude: -74.0,
                                             nighttimeOffsetMinutes: 0, daytimeOffsetMinutes: 0), timeZone: nyTZ)
            if let next = sun.nextTransition(after: at(2024, 6, 1, 12, 0)) {
                t.check(next.phase == .night, "sun: next after noon is Dark (sunset)")
            } else { t.check(false, "sun: expected a next transition") }
        }

        // --- Override expiry (feature 1) ---
        do {
            print("Override expiry:")
            let ov = Override(reason: .pausedDuration, until: at(2024, 1, 10, 13, 0))
            t.check(ov.isActive(at: at(2024, 1, 10, 12, 30)), "active 30m before until")
            t.check(!ov.isActive(at: at(2024, 1, 10, 13, 0)), "expired exactly at until")
            t.check(!ov.isActive(at: at(2024, 1, 10, 14, 0)), "expired after until")
        }

        // --- Phase/effect selection and enforcement state machine ---
        do {
            print("Schedule effects engine:")
            let boundary = at(2024, 1, 10, 20, 0)
            let darkOnly = ScheduleEffects(darkAppearance: true, nightShift: false)
            let nightShiftOnly = ScheduleEffects(darkAppearance: false, nightShift: true)
            let combined = ScheduleEffects(darkAppearance: true, nightShift: true)
            let neither = ScheduleEffects(darkAppearance: false, nightShift: false)

            let nightOnlyNight = EnforcementEngine.decide(
                now: at(2024, 1, 10, 21, 0), phase: .night,
                effects: nightShiftOnly, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .dark,
                override: nil, nextBoundary: at(2024, 1, 11, 7, 0))
            t.check(nightOnlyNight.appearance == nil && nightOnlyNight.nightShift == true,
                    "Night Shift-only nighttime turns warmth on and leaves Light appearance untouched")
            t.check(nightOnlyNight.override == nil,
                    "Night Shift-only Light appearance is not a false manual override")

            let nightOnlyDay = EnforcementEngine.decide(
                now: at(2024, 1, 11, 8, 0), phase: .day,
                effects: nightShiftOnly, nightShiftAvailable: true,
                currentAppearance: .dark, lastAppearanceBaseline: .light,
                override: nil, nextBoundary: at(2024, 1, 11, 20, 0))
            t.check(nightOnlyDay.appearance == nil && nightOnlyDay.nightShift == false,
                    "Night Shift-only daytime turns warmth off without changing Dark appearance")

            let dark = EnforcementEngine.decide(
                now: at(2024, 1, 10, 21, 0), phase: .night,
                effects: darkOnly, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .light,
                override: nil, nextBoundary: at(2024, 1, 11, 7, 0))
            t.check(dark.appearance == .dark && dark.nightShift == nil,
                    "Dark-only nighttime enforces Dark without Night Shift")

            let both = EnforcementEngine.decide(
                now: at(2024, 1, 10, 21, 0), phase: .night,
                effects: combined, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .light,
                override: nil, nextBoundary: at(2024, 1, 11, 7, 0))
            t.check(both.appearance == .dark && both.nightShift == true,
                    "combined nighttime reconciles both effects")

            let empty = EnforcementEngine.decide(
                now: at(2024, 1, 10, 21, 0), phase: .night,
                effects: neither, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .dark,
                override: nil, nextBoundary: boundary)
            t.check(empty.appearance == nil && empty.nightShift == nil && empty.override == nil,
                    "neither selected produces no mutations or false override")

            let unavailable = EnforcementEngine.decide(
                now: at(2024, 1, 10, 21, 0), phase: .night,
                effects: combined, nightShiftAvailable: false,
                currentAppearance: .light, lastAppearanceBaseline: .light,
                override: nil, nextBoundary: boundary)
            t.check(unavailable.appearance == .dark && unavailable.nightShift == nil,
                    "unavailable Night Shift disables only that effect")

            let manual = EnforcementEngine.decide(
                now: at(2024, 1, 10, 12, 0), phase: .day,
                effects: darkOnly, nightShiftAvailable: true,
                currentAppearance: .dark, lastAppearanceBaseline: .light,
                override: nil, nextBoundary: boundary)
            t.check(manual.appearance == nil && manual.override?.reason == .manual,
                    "manual Dark appearance divergence pauses the schedule")

            let pause = Override(reason: .pausedDuration, until: at(2024, 1, 10, 13, 0))
            let paused = EnforcementEngine.decide(
                now: at(2024, 1, 10, 12, 30), phase: .day,
                effects: combined, nightShiftAvailable: true,
                currentAppearance: .dark, lastAppearanceBaseline: .light,
                override: pause, nextBoundary: boundary)
            t.check(paused.appearance == nil && paused.nightShift == nil,
                    "pause suspends every scheduled effect")

            let resumed = EnforcementEngine.decide(
                now: at(2024, 1, 10, 13, 1), phase: .day,
                effects: combined, nightShiftAvailable: true,
                currentAppearance: .dark, lastAppearanceBaseline: .dark,
                override: pause, nextBoundary: boundary)
            t.check(resumed.override == nil && resumed.appearance == .light && resumed.nightShift == false,
                    "expired pause resumes and reconciles every enabled effect")

            let early = Override(reason: .earlySwitch, until: boundary)
            let held = EnforcementEngine.decide(
                now: at(2024, 1, 10, 15, 0), phase: .day,
                effects: nightShiftOnly, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .light,
                override: early, nextBoundary: boundary)
            t.check(held.appearance == nil && held.nightShift == nil,
                    "switch-early override holds selected effects until the boundary")
            let rejoin = EnforcementEngine.decide(
                now: at(2024, 1, 10, 20, 1), phase: .night,
                effects: nightShiftOnly, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .light,
                override: early, nextBoundary: at(2024, 1, 11, 7, 0))
            t.check(rejoin.override == nil && rejoin.appearance == nil && rejoin.nightShift == true,
                    "switch early rejoins a Night Shift-only schedule at expiry")

            let wakeReconcile = EnforcementEngine.decide(
                now: at(2024, 1, 10, 20, 5), phase: .night,
                effects: combined, nightShiftAvailable: true,
                currentAppearance: .light, lastAppearanceBaseline: .light,
                override: nil, nextBoundary: at(2024, 1, 11, 7, 0))
            t.check(wakeReconcile.appearance == .dark && wakeReconcile.nightShift == true,
                    "wake after a boundary reconciles the current phase")

            let knownChange = NightShiftMutationPlanner.plan(
                desired: true, live: false, lastApplied: false)
            t.check(knownChange.mutation == true && knownChange.isKnownChange,
                    "live Night Shift drift requests a proven mutation")
            t.check(NightShiftMutationPlanner.plan(
                desired: true, live: true, lastApplied: false
            ).mutation == nil, "live matching state is idempotent despite a stale cache")
            let failedAttempt = NightShiftMutationPlanner.plan(
                desired: true, live: false, lastApplied: false)
            let retry = NightShiftMutationPlanner.plan(
                desired: true, live: false, lastApplied: false)
            t.check(failedAttempt == retry && retry.mutation == true,
                    "failed Night Shift mutation retries when state remains unchanged")
            let unknown = NightShiftMutationPlanner.plan(
                desired: true, live: nil, lastApplied: nil)
            t.check(unknown.mutation == true && !unknown.isKnownChange,
                    "unknown launch state reconciles without claiming a known change")
            t.check(NightShiftMutationPlanner.plan(
                desired: nil, live: false, lastApplied: true
            ).mutation == nil, "unselected or unavailable Night Shift is never mutated")
            t.check(!NightShiftOwnershipPolicy.ownershipAfterSuccessfulMutation(
                previous: false, mutation: true, isKnownChange: false
            ), "unknown/redundant enable does not claim user-owned Night Shift")
            let owned = NightShiftOwnershipPolicy.ownershipAfterSuccessfulMutation(
                previous: false, mutation: true, isKnownChange: true
            )
            t.check(owned && NightShiftOwnershipPolicy.needsCleanupWhenDisabled(
                ownedActive: owned
            ), "proven scheduler enable requires cleanup on opt-out")
            t.check(!NightShiftOwnershipPolicy.ownershipAfterSuccessfulMutation(
                previous: true, mutation: false, isKnownChange: true
            ), "successful deactivation releases scheduler ownership")
        }

        // --- Transition fire-delay (arming the on-time boundary timer) ---
        do {
            print("Transition fire delay:")
            let now = at(2024, 1, 10, 12, 0)
            // No upcoming transition → nil (nothing to schedule).
            t.check(Scheduler.fireDelay(until: nil, now: now) == nil, "nil transition → no timer")
            // Future transition → (date − now) + 1s cushion.
            let future = Transition(date: at(2024, 1, 10, 20, 0), phase: .night)
            if let delay = Scheduler.fireDelay(until: future, now: now) {
                t.check(abs(delay - (8 * 3600 + 1)) < 0.001, "future transition → fires at boundary +1s")
            } else { t.check(false, "future transition should yield a delay") }
            // Past/already-due transition → nil (caller enforces immediately).
            let past = Transition(date: at(2024, 1, 10, 11, 0), phase: .day)
            t.check(Scheduler.fireDelay(until: past, now: now) == nil, "past transition → no timer")
            let pauseExpiry = at(2024, 1, 10, 13, 0)
            let nextBoundary = at(2024, 1, 10, 20, 0)
            t.check(Scheduler.fireDelay(
                untilNextOf: [nextBoundary, pauseExpiry], now: now
            ) == 3601, "one-hour pause expiry arms before the next phase boundary")
        }

        // --- Override migration: the Reason decoder tolerates unknown cases ---
        do {
            print("Override Reason decoding (migration-safe):")
            let enc = JSONEncoder()
            let dec = JSONDecoder()

            // A .preview override round-trips exactly.
            let original = Override(reason: .preview, until: at(2024, 1, 10, 20, 0))
            if let data = try? enc.encode(original),
               let back = try? dec.decode(Override.self, from: data) {
                t.check(back == original, "preview override round-trips through Codable")
            } else { t.check(false, "preview override should encode/decode") }

            // An archive with a reason this build doesn't know maps to .manual
            // rather than throwing and discarding the whole override.
            let bogus = "{\"reason\":\"someFutureReason\",\"until\":740000000}".data(using: .utf8)!
            if let back = try? dec.decode(Override.self, from: bogus) {
                t.check(back.reason == .manual, "unknown reason decodes to .manual (not a decode failure)")
            } else { t.check(false, "unknown reason should decode leniently, not throw") }

            // Legacy reasons still decode to themselves.
            let legacy = "{\"reason\":\"pausedUntilBoundary\",\"until\":740000000}".data(using: .utf8)!
            if let back = try? dec.decode(Override.self, from: legacy) {
                t.check(back.reason == .pausedUntilBoundary, "legacy pausedUntilBoundary still decodes correctly")
            } else { t.check(false, "legacy reason should decode") }
        }

        // --- Scheduled-effect defaults and migration from 2.7 ---
        do {
            print("Scheduled effect settings migration:")
            let suite = "DarkModeSchedulerTests.\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: suite) {
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.removePersistentDomain(forName: suite)
                let store = SettingsStore(defaults: defaults)

                t.check(store.darkAppearanceEnabled,
                        "fresh install defaults Dark appearance on")
                t.check(!store.nightShiftEnabled,
                        "fresh install defaults Night Shift off")

                defaults.set(true, forKey: "nightShiftEnabled")
                defaults.set(21 * 60, forKey: "fixedDarkMinutes")
                defaults.set(-30, forKey: "darkOffsetMinutes")
                t.check(store.scheduleEffects == ScheduleEffects(
                    darkAppearance: true, nightShift: true
                ), "existing Night Shift preference migrates with Dark appearance enabled")
                t.check(store.fixedNighttimeMinutes == 21 * 60
                        && store.nighttimeOffsetMinutes == -30,
                        "legacy nighttime boundary and offset keys remain compatible")

                store.darkAppearanceEnabled = false
                t.check(!store.darkAppearanceEnabled && store.nightShiftEnabled,
                        "Dark appearance selection persists independently")

                store.nightShiftOwnedActive = true
                store.nightShiftCleanupPending = true
                let relaunched = SettingsStore(defaults: defaults)
                t.check(relaunched.nightShiftOwnedActive
                        && relaunched.nightShiftCleanupPending,
                        "Night Shift ownership and failed cleanup persist across relaunch")
            } else {
                t.check(false, "created isolated UserDefaults suite")
            }
        }

        t.finish()
    }
}
