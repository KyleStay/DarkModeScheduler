# Dark Mode Scheduler

A native macOS **menu bar app** that automatically switches the system
appearance to **Dark at night** and **Light during the day** — on a **sun-based**
schedule (computed locally from your location) or at **fixed times** you choose.
It's the manual alternative to macOS's built-in Location-Services "Auto"
appearance: useful if you keep Location Services off, want explicit times, or
want per-transition tuning.

- **Sun times are computed locally** using the NOAA sunrise/sunset algorithm
  (`SunCalculator.swift`). No network is used for sun math.
- **The only outbound network call** is postal-code → latitude/longitude
  geocoding, via the free, key-less [Zippopotam](https://zippopotam.us) API. The
  result is cached; it's only re-fetched when you change the postal code.
- Menu-bar-only (`LSUIElement`) — no Dock icon.
- Swift + SwiftUI `MenuBarExtra`, macOS 13+. **Zero third-party dependencies.**

---

## Features

| # | Feature | Summary |
|---|---------|---------|
| 1 | **Manual override / pause** | Pause for 1 hour, pause until the next sunrise/sunset, or resume now. If you flip the appearance yourself (e.g. Control Center), the app detects it and honors your choice until the next scheduled boundary instead of snapping back. Override state is shown in the popover and persists across relaunch. |
| 2 | **Fixed-schedule mode** | Toggle between *Sun-based* and *Fixed times* (pick explicit Dark-at / Light-at clock times). All scheduling, wake, and idempotency logic works identically in both modes. |
| 3 | **Sun-time offsets** | In sun mode, shift each transition (e.g. "Dark 30 min before sunset", "Light 15 min after sunrise"), ±180 min, applied on top of the NOAA math. |
| 4 | **Optional auto-location** | A "My Location" source uses CoreLocation as an alternative to a manual postal code, with clear inline UI for every authorization state. Postal code stays the default and the fallback; Location Services is entirely optional. |
| 5 | **Non-US locations** | Enter a country code + postal code (e.g. `GB SW1`, `DE 10115`). US 5-digit zips remain the default happy path. Differing response shapes and not-found/offline cases are handled gracefully. |
| 6 | **Switch notifications** (opt-in, default off) | Optionally posts a "Switched to Dark/Light" notification on an actual switch. Authorization is requested only when you enable it, and redundant (idempotent) no-op ticks never notify. |
| 7 | **Menu-bar glance** | The menu-bar item's tooltip and accessibility label surface the next transition (mode + time) — or the current pause state — without opening the popover. |
| 8 | **Night Shift coordination** (opt-in, default off) | Ties warm color temperature to the same schedule (warm at night, off during day). See the caveat below. |

---

## Requirements

- macOS 13.0 (Ventura) or later.
- The Swift toolchain that ships with the Xcode command-line tools
  (`/usr/bin/swiftc`). No Xcode project, SPM packages, or other installs.

## Build

```bash
./build.sh
```

This compiles all Swift sources with `swiftc` (`-warnings-as-errors`, so the
build is warnings-clean by contract), assembles `DarkModeScheduler.app` with a
correct `Info.plist`, and ad-hoc code-signs it (`codesign -s - --deep`). It
builds a **universal** (x86_64 + arm64) binary when both slices compile,
otherwise the host architecture only. The script is idempotent and fails loudly
(`set -euo pipefail`).

Output: `./DarkModeScheduler.app`

## Run

```bash
open DarkModeScheduler.app
```

A sun/moon icon appears in the menu bar. Click it to open the popover.

---

## Permissions

The app requests only what a feature needs, and only when that feature is used.

| Permission | When | Required for |
|------------|------|--------------|
| **Automation** (System Events) | First appearance switch | Live-switching Dark/Light (core). Until granted, the popover shows an inline hint and logs `-1743` instead of crashing. |
| **Location Services** | Only if you pick "My Location" | Feature 4. Fully optional — postal code works without it. |
| **Notifications** | Only if you enable "Notify on switch" | Feature 6. |

### First run — Automation permission (important)

To live-switch the system appearance, the app tells **System Events** to toggle
Dark Mode via AppleScript. The **first time** it does this, macOS shows an
**Automation** permission prompt:

> "Dark Mode Scheduler" wants access to control "System Events".

Click **OK / Allow**. If you dismiss it, the popover shows an inline hint and you
can grant access later at **System Settings → Privacy & Security → Automation →
Dark Mode Scheduler → enable "System Events"**. Until this is granted, the app
cannot change the appearance (it logs `-1743` / `errAEEventNotPermitted` and
surfaces the hint instead of crashing or spinning).

---

## Using it

### Location (postal code — the default)

Open the popover, keep the source on **Postal code**, enter a country code
(default `US`) and a postal code, and press **Save** (or Return). The app
geocodes it once, caches `{code, country, lat, lon, city, state}`, shows the
resolved place, and (in sun mode) today's sunrise/sunset. Invalid input,
not-found, and offline errors are shown inline. Changing the location
immediately re-evaluates and enforces the correct appearance.

### Location (My Location — optional)

Switch the source to **My Location** to use CoreLocation. The app drives the
authorization flow and shows the current state inline (ask / denied → open
Settings / granted → refresh). If you deny it, postal code remains available.

### Schedule mode & tuning

- **Sun-based:** optionally offset each transition (Dark relative to sunset,
  Light relative to sunrise), ±180 minutes in 5-minute steps.
- **Fixed times:** pick a Dark-at and a Light-at clock time.

### Pause / override

- **Pause 1 hour** — suspend enforcement for an hour.
- **Pause until next sunrise/sunset** — resume at the next natural boundary.
- **Resume schedule now** — clear any pause/override and enforce immediately.
- **Manual flip** — if you change the appearance yourself while the app is
  running, it treats that as an override until the next scheduled boundary
  rather than correcting you on the next tick.

The current override and when it ends are shown in the popover; the state
persists across relaunch.

### Launch at login

Toggle **Launch at Login** in the popover. This uses `SMAppService.mainApp`
(macOS 13+); the toggle reflects the real registration status and surfaces any
error. (macOS may show its own approval UI under System Settings → General →
Login Items.)

---

## How scheduling works

- The schedule (sun or fixed) is reduced to a sorted list of **transitions**
  across a ±day window. The **desired mode** is the mode of the most recent
  transition at/before now; the **next transition** is the first one after now.
  Both modes share this logic, so wake handling, idempotency, and the glance are
  identical for each.
- A 60-second `Timer` re-evaluates and enforces. It also re-evaluates
  immediately **on launch**, **on any settings change**, and **on system wake**
  (`NSWorkspace.didWakeNotification`).
- **Idempotent:** the AppleScript switch is issued **only** when the live
  appearance differs from the desired one — no redundant calls, no flicker, and
  notifications fire only on real switches.

### The enforcement state machine

Every evaluation runs through one pure decision (`EnforcementEngine.decide`):

1. **Expire** a due override.
2. **Suspend** while an override is active (accept whatever appearance you've set).
3. **Detect a manual divergence** — if the live appearance differs from both the
   schedule *and* what the app last set, only you could have done that, so honor
   it as an override until the next boundary.
4. Otherwise **enforce** the scheduled mode idempotently.

All three pause kinds are one representation — `Override { reason, until }` — so
there is exactly one suspended state, not three.

---

## Night Shift caveat (feature 8)

**Night Shift has no public API.** It is controlled by the private
`CBBlueLightClient` class in the `CoreBrightness` framework. This app:

- **Isolates** all private-API contact behind a `NightShiftControlling` protocol.
- **Loads the framework at runtime** (`dlopen`) and resolves the class and its
  methods dynamically via the Objective-C runtime — it does **not** link the
  private framework, which would risk a launch-time failure across OS versions.
- **Guards every step.** If the framework, class, or method is missing, the
  feature reports **"Unavailable on this Mac"** and the toggle is disabled — it
  never fakes success.
- Only touches Night Shift when you opt in; turning the toggle off restores warm
  mode to off.

**Risk:** because this relies on a private, undocumented interface, a future
macOS release could rename or remove it. If that happens, the toggle will simply
show as unavailable rather than misbehaving. Verified working on macOS 15; the
warm color temperature follows the same Dark/Light schedule.

---

## Developer notes

### Run the unit tests (no GUI required)

```bash
./run-tests.sh
```

`SunCalculatorTests.swift` is a self-contained assertion runner (its own `@main`,
not an XCTest bundle). It checks computed sunrise/sunset against **U.S. Naval
Observatory** reference values (±2 min), plus DST-awareness and polar edge cases,
**and** the v2 scheduling core: sun-time offset math, fixed-schedule boundary
logic (including inverted schedules), next-transition computation, override
expiry, and the `EnforcementEngine` state machine (manual divergence, suspend,
resume, and no-false-trigger on schedule advance). It compiles only the pure
files (`SunCalculatorTests.swift SunCalculator.swift Scheduler.swift`) and exits
non-zero on any failure.

### Hidden self-test (`--selftest`)

```bash
./DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler --selftest
```

Runs two kinds of checks without launching the GUI:

- **Pure** (no permissions): the scheduling & state-machine logic — offsets,
  fixed-mode boundaries, next-transition, override expiry, and the
  divergence/suspend/enforce decisions.
- **Live** (needs Automation permission): forces a real switch and verifies the
  live `AppleInterfaceStyle` changed, confirms idempotency (no AppleScript when
  already at the desired mode), and restores the original appearance.

If Automation permission hasn't been granted, it reports the `-1743` condition
and what to click — it cannot complete the live half headlessly until a human
grants that permission once. Exits 0 on success.

## File tree

```
Darkmode scheduler/
├── main.swift               # SwiftUI App/Scene, --selftest, entry dispatch.
├── AppModel.swift           # @MainActor orchestrator: timer, wake, tick,
│                            #   applies EnforcementEngine decisions, persistence.
├── PopoverView.swift        # The MenuBarExtra popover UI (all 8 features).
├── Services.swift           # AppearanceController, GeocodeService (intl),
│                            #   LocationService (CoreLocation), NotificationService,
│                            #   NightShiftController (private CBBlueLightClient).
├── Support.swift            # Logging, ResolvedLocation (+v1 migration), errors,
│                            #   SettingsStore (UserDefaults).
├── Scheduler.swift          # PURE core: AppearanceMode, ScheduleMode, Transition,
│                            #   Scheduler (sun+fixed), Override, EnforcementEngine.
├── SunCalculator.swift      # Pure NOAA sunrise/sunset math (shared with tests).
├── SunCalculatorTests.swift # Standalone, GUI-free unit tests (@main runner).
├── build.sh                 # Compile + bundle + Info.plist + ad-hoc codesign.
├── run-tests.sh             # Compile + run the unit tests.
├── README.md                # This file.
└── DarkModeScheduler.app    # Build output (created by build.sh).
```
