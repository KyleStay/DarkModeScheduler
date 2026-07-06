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
                                               darkOffsetMinutes: -30, lightOffsetMinutes: 15),
                                  timeZone: nyTZ)
            let dayStart = midnight(2024, 6, 1)
            let dayEnd = midnight(2024, 6, 2)
            let onDay = sched.transitions(around: noon(day(2024, 6, 1), nyTZ))
                .filter { $0.date >= dayStart && $0.date < dayEnd }
            if case .time(let sunset) = base.sunset,
               let dark = onDay.first(where: { $0.mode == .dark }) {
                let delta = sunset.timeIntervalSince(dark.date)
                t.check(abs(delta - 1800) < 30, "dark offset lands 30m before sunset (Δ \(Int(delta))s)")
            } else { t.check(false, "offset: found dark transition on day") }
            if case .time(let sunrise) = base.sunrise,
               let light = onDay.first(where: { $0.mode == .light }) {
                let delta = light.date.timeIntervalSince(sunrise)
                t.check(abs(delta - 900) < 30, "light offset lands 15m after sunrise (Δ \(Int(delta))s)")
            } else { t.check(false, "offset: found light transition on day") }
        }

        // --- Fixed-schedule boundary logic (feature 2) ---
        do {
            print("Fixed schedule — Dark 20:00 / Light 07:00:")
            let s = Scheduler(config: .fixed(darkMinutes: 20 * 60, lightMinutes: 7 * 60), timeZone: nyTZ)
            t.check(s.desiredMode(at: at(2024, 1, 10, 21, 0)) == .dark, "21:00 → Dark")
            t.check(s.desiredMode(at: at(2024, 1, 10, 6, 59)) == .dark, "06:59 → Dark")
            t.check(s.desiredMode(at: at(2024, 1, 10, 7, 1)) == .light, "07:01 → Light")
            t.check(s.desiredMode(at: at(2024, 1, 10, 19, 59)) == .light, "19:59 → Light")
            t.check(s.desiredMode(at: at(2024, 1, 10, 0, 30)) == .dark, "00:30 → Dark")
        }

        // --- Inverted fixed schedule (Dark before Light within the day) ---
        do {
            print("Fixed schedule (inverted) — Dark 09:00 / Light 18:00:")
            let s = Scheduler(config: .fixed(darkMinutes: 9 * 60, lightMinutes: 18 * 60), timeZone: nyTZ)
            t.check(s.desiredMode(at: at(2024, 1, 10, 12, 0)) == .dark, "12:00 → Dark (between)")
            t.check(s.desiredMode(at: at(2024, 1, 10, 20, 0)) == .light, "20:00 → Light (after)")
            t.check(s.desiredMode(at: at(2024, 1, 10, 6, 0)) == .light, "06:00 → Light (before)")
        }

        // --- Fixed times are DST-anchored to wall-clock, not elapsed seconds ---
        do {
            print("Fixed schedule DST anchoring — America/New_York:")
            let s = Scheduler(config: .fixed(darkMinutes: 20 * 60, lightMinutes: 7 * 60), timeZone: nyTZ)
            // Spring-forward day (clocks jump 02:00→03:00). A raw midnight+7h would
            // land at 08:00; the fix must keep the Light transition at 07:00.
            let springNoon = at(2024, 3, 10, 12, 0)
            if let light = s.transitions(around: springNoon)
                .first(where: { nyCal.isDate($0.date, inSameDayAs: springNoon) && $0.mode == .light }) {
                let c = nyCal.dateComponents([.hour, .minute], from: light.date)
                t.check(c.hour == 7 && c.minute == 0, "spring-forward Light stays 07:00 (got \(c.hour ?? -1):\(c.minute ?? -1))")
            } else { t.check(false, "DST: found spring-forward Light transition") }
            // Fall-back day (clocks 02:00→01:00). Dark at 20:00 must stay 20:00.
            let fallNoon = at(2024, 11, 3, 12, 0)
            if let dark = s.transitions(around: fallNoon)
                .first(where: { nyCal.isDate($0.date, inSameDayAs: fallNoon) && $0.mode == .dark }) {
                let c = nyCal.dateComponents([.hour, .minute], from: dark.date)
                t.check(c.hour == 20 && c.minute == 0, "fall-back Dark stays 20:00 (got \(c.hour ?? -1):\(c.minute ?? -1))")
            } else { t.check(false, "DST: found fall-back Dark transition") }
        }

        // --- Next-transition computation (both modes) ---
        do {
            print("Next transition:")
            let fixed = Scheduler(config: .fixed(darkMinutes: 20 * 60, lightMinutes: 7 * 60), timeZone: nyTZ)
            if let next = fixed.nextTransition(after: at(2024, 1, 10, 12, 0)) {
                let comps = nyCal.dateComponents([.hour, .minute], from: next.date)
                t.check(next.mode == .dark && comps.hour == 20 && comps.minute == 0,
                        "fixed: next after 12:00 is Dark@20:00")
            } else { t.check(false, "fixed: expected a next transition") }
            if let next = fixed.nextTransition(after: at(2024, 1, 10, 21, 0)) {
                let comps = nyCal.dateComponents([.hour, .minute], from: next.date)
                t.check(next.mode == .light && comps.hour == 7,
                        "fixed: next after 21:00 is Light@07:00 (next day)")
            } else { t.check(false, "fixed: expected a next transition after 21:00") }

            let sun = Scheduler(config: .sun(latitude: 40.71, longitude: -74.0,
                                             darkOffsetMinutes: 0, lightOffsetMinutes: 0), timeZone: nyTZ)
            if let next = sun.nextTransition(after: at(2024, 6, 1, 12, 0)) {
                t.check(next.mode == .dark, "sun: next after noon is Dark (sunset)")
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

        // --- Enforcement state machine (feature 1, the crux) ---
        do {
            print("Enforcement engine:")
            let boundary = at(2024, 1, 10, 20, 0)
            // Manual flip: live ≠ scheduled AND live ≠ lastEnforced → suspend w/ .manual.
            let manual = EnforcementEngine.decide(now: at(2024, 1, 10, 12, 0),
                                                  currentMode: .dark, scheduledMode: .light,
                                                  lastEnforced: .light, override: nil, nextBoundary: boundary)
            t.check(manual.enforce == nil && manual.override?.reason == .manual,
                    "manual flip → suspend with .manual override until boundary")
            t.check(manual.override?.until == boundary, "manual override expires at next boundary")

            // Still suspended before expiry, even if user flips again.
            let stillPaused = EnforcementEngine.decide(now: at(2024, 1, 10, 15, 0),
                                                       currentMode: .light, scheduledMode: .light,
                                                       lastEnforced: .dark, override: manual.override,
                                                       nextBoundary: boundary)
            t.check(stillPaused.enforce == nil, "override active → stays suspended")

            // After a timed pause expires (user untouched, so lastEnforced tracks
            // the appearance we set), we resume and enforce the schedule.
            let timedPause = Override(reason: .pausedDuration, until: at(2024, 1, 10, 13, 0))
            let resumed = EnforcementEngine.decide(now: at(2024, 1, 10, 13, 1),
                                                   currentMode: .light, scheduledMode: .dark,
                                                   lastEnforced: .light, override: timedPause,
                                                   nextBoundary: boundary)
            t.check(resumed.override == nil && resumed.enforce == .dark,
                    "expired override → resume & enforce schedule")

            // Nuance: if the user re-flips appearance exactly as an override
            // expires, that fresh divergence becomes a new manual override.
            let reflip = EnforcementEngine.decide(now: at(2024, 1, 10, 13, 1),
                                                  currentMode: .dark, scheduledMode: .light,
                                                  lastEnforced: .light, override: timedPause,
                                                  nextBoundary: boundary)
            t.check(reflip.enforce == nil && reflip.override?.reason == .manual,
                    "re-flip at expiry → new manual override (not snapped back)")

            // Schedule merely advancing past a boundary is NOT a manual flip.
            let advance = EnforcementEngine.decide(now: at(2024, 1, 10, 20, 1),
                                                   currentMode: .light, scheduledMode: .dark,
                                                   lastEnforced: .light, override: nil, nextBoundary: boundary)
            t.check(advance.override == nil && advance.enforce == .dark,
                    "schedule advance → enforce (no false manual override)")

            // Matching state: idempotent enforce, no override.
            let match = EnforcementEngine.decide(now: at(2024, 1, 10, 12, 0),
                                                 currentMode: .light, scheduledMode: .light,
                                                 lastEnforced: .light, override: nil, nextBoundary: boundary)
            t.check(match.enforce == .light && match.override == nil, "matched state → enforce (no-op) no override")

            // Timed pause suspends regardless of appearance agreement.
            let paused = Override(reason: .pausedDuration, until: at(2024, 1, 10, 13, 0))
            let timed = EnforcementEngine.decide(now: at(2024, 1, 10, 12, 0),
                                                 currentMode: .light, scheduledMode: .dark,
                                                 lastEnforced: .light, override: paused, nextBoundary: boundary)
            t.check(timed.enforce == nil && timed.override?.reason == .pausedDuration,
                    "timed pause → suspend even when schedule wants a change")
        }

        t.finish()
    }
}
