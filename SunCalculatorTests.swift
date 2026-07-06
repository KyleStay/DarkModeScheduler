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

        t.finish()
    }
}
