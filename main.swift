import SwiftUI
import AppKit
import Foundation

// =============================================================================
// main.swift — the SwiftUI App/Scene, the hidden `--selftest` CLI path, and the
// top-level entry dispatch. All model/scheduling/UI logic lives in the other
// files (Scheduler / Support / Services / AppModel / PopoverView), compiled
// together into this single binary by build.sh.
// =============================================================================

// MARK: - App

struct DarkModeSchedulerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            // Feature 7 — menu-bar glance: the icon reflects the live appearance,
            // and the next transition (mode + time) is surfaced without opening
            // the popover via the item's help tooltip and accessibility label.
            Image(systemName: model.currentMode.isDark ? "moon.stars" : "sun.max")
                .help(model.glanceSummary)
                .accessibilityLabel(model.glanceSummary)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Self test (hidden `--selftest` CLI path; not on the user path)

/// Command-line self-test used by build/CI verification. It runs two kinds of
/// checks, all without launching the GUI:
///   • PURE (no permissions): the scheduling & state-machine logic — offsets,
///     fixed-mode boundaries, next-transition, override expiry, and the manual
///     divergence / suspend / enforce decisions.
///   • LIVE (needs Automation permission): forces a real appearance switch,
///     verifies it, confirms idempotency, and restores. If permission hasn't
///     been granted it reports the -1743 condition instead of crashing.
/// Exits 0 on success, non-zero on unexpected failure.
enum SelfTest {
    static func run() -> Never {
        print("=== Dark Mode Scheduler self-test ===")
        var failures = 0
        failures += runPureChecks()
        failures += runLiveChecks()
        print(failures == 0 ? "\n[selftest] ALL SELF-TESTS PASSED ✅"
                            : "\n[selftest] \(failures) SELF-TEST(S) FAILED ❌")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Pure checks (no permissions required)

    private static func runPureChecks() -> Int {
        print("\n[selftest] --- pure scheduling & state-machine checks ---")
        var failures = 0
        func check(_ cond: Bool, _ label: String) {
            print(cond ? "  ✅ \(label)" : "  ❌ \(label)")
            if !cond { failures += 1 }
        }

        let tz = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }

        // Fixed-mode boundary logic: Dark 20:00, Light 07:00.
        let fixed = Scheduler(config: .fixed(darkMinutes: 20 * 60, lightMinutes: 7 * 60), timeZone: tz)
        check(fixed.desiredMode(at: at(2024, 6, 1, 21, 0)) == .dark, "fixed: 21:00 is Dark")
        check(fixed.desiredMode(at: at(2024, 6, 1, 12, 0)) == .light, "fixed: 12:00 is Light")
        check(fixed.desiredMode(at: at(2024, 6, 1, 3, 0)) == .dark, "fixed: 03:00 is Dark")
        if let next = fixed.nextTransition(after: at(2024, 6, 1, 12, 0)) {
            check(next.mode == .dark, "fixed: next after noon is Dark")
        } else { check(false, "fixed: expected a next transition") }

        // Sun-mode offsets: Dark 30m before sunset must precede the un-offset sunset.
        let plain = Scheduler(config: .sun(latitude: 40.71, longitude: -74.0,
                                           darkOffsetMinutes: 0, lightOffsetMinutes: 0), timeZone: tz)
        let shifted = Scheduler(config: .sun(latitude: 40.71, longitude: -74.0,
                                             darkOffsetMinutes: -30, lightOffsetMinutes: 15), timeZone: tz)
        let noon = at(2024, 6, 1, 12, 0)
        if let plainDark = plain.transitions(around: noon).first(where: { $0.mode == .dark && $0.date > noon }),
           let shiftDark = shifted.transitions(around: noon).first(where: { $0.mode == .dark && $0.date > noon }) {
            let delta = plainDark.date.timeIntervalSince(shiftDark.date)
            check(abs(delta - 1800) < 1, "sun: -30m dark offset lands 30m before sunset")
        } else { check(false, "sun: could not find dark transitions") }

        // Override expiry.
        let ov = Override(reason: .pausedDuration, until: at(2024, 6, 1, 13, 0))
        check(ov.isActive(at: at(2024, 6, 1, 12, 30)), "override: active before expiry")
        check(!ov.isActive(at: at(2024, 6, 1, 13, 30)), "override: expired after until")

        // State machine: manual divergence → suspend, then expiry → enforce.
        let boundary = at(2024, 6, 1, 20, 0)
        let d1 = EnforcementEngine.decide(now: at(2024, 6, 1, 12, 0),
                                          currentMode: .dark, scheduledMode: .light,
                                          lastEnforced: .light, override: nil, nextBoundary: boundary)
        check(d1.enforce == nil && d1.override?.reason == .manual,
              "engine: manual flip → suspend with .manual override")
        let d2 = EnforcementEngine.decide(now: at(2024, 6, 1, 12, 1),
                                          currentMode: .dark, scheduledMode: .light,
                                          lastEnforced: .dark, override: d1.override, nextBoundary: boundary)
        check(d2.enforce == nil, "engine: still suspended before boundary")
        let d3 = EnforcementEngine.decide(now: at(2024, 6, 1, 20, 1),
                                          currentMode: .dark, scheduledMode: .dark,
                                          lastEnforced: .dark, override: d1.override, nextBoundary: boundary)
        check(d3.override == nil && d3.enforce == .dark, "engine: after boundary → resume & enforce")
        // Schedule advancing (not a manual flip) must enforce, not suspend.
        let d4 = EnforcementEngine.decide(now: at(2024, 6, 1, 20, 5),
                                          currentMode: .light, scheduledMode: .dark,
                                          lastEnforced: .light, override: nil, nextBoundary: boundary)
        check(d4.enforce == .dark && d4.override == nil, "engine: schedule advance → enforce (no false override)")

        return failures
    }

    // MARK: Live checks (need Automation permission)

    private static func runLiveChecks() -> Int {
        print("\n[selftest] --- live appearance enforcement checks ---")
        let controller = AppearanceController()
        let original = controller.currentMode()
        print("[selftest] original appearance: \(original.label)")

        let target: AppearanceMode = (original == .dark) ? .light : .dark
        var failures = 0

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

        print("[selftest] enforcing \(target.label) again to check idempotency…")
        let repeatOutcome = controller.enforce(desired: target)
        print("[selftest]   → \(issued(repeatOutcome))")
        if case .unchanged = repeatOutcome {
            print("[selftest] ✅ idempotent: no AppleScript issued when already at desired")
        } else {
            print("[selftest] ❌ expected .unchanged, got \(repeatOutcome)")
            failures += 1
        }

        print("[selftest] restoring original appearance (\(original.label))…")
        let restore = controller.enforce(desired: original)
        let restored = waitForMode(original, controller: controller)
        if restored == original {
            print("[selftest] ✅ restored to \(original.label) (outcome: \(restore))")
        } else {
            print("[selftest] ⚠️ could not confirm restore (now \(restored.label))")
        }
        return failures
    }

    private static func issued(_ outcome: EnforceOutcome) -> String {
        switch outcome {
        case .unchanged: return "AppleScript issued: NO  (idempotent no-op)"
        case .applied: return "AppleScript issued: YES (state changed)"
        case .failedPermission: return "AppleScript issued: YES but blocked (permission -1743)"
        case .failed(let code): return "AppleScript issued: YES but failed (code \(code))"
        }
    }

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
// the SwiftUI app so the pure and live checks are scriptable without any GUI.

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()  // never returns
}

DarkModeSchedulerApp.main()
