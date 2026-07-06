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

## Install (end users)

Download **`DarkModeScheduler.dmg`**, double-click it, and **drag the app onto the
Applications folder** shown in the window. Then launch it from Applications — a
sun/moon icon appears in the menu bar; click it to open the popover.

The release DMG is **signed with a Developer ID and notarized by Apple**, so
Gatekeeper opens it with no "unidentified developer" warning. (See
[Distribution](#distribution-signed--notarized-release) for how the DMG is
produced.) The **first time** it changes the appearance, macOS asks for
**Automation** permission — click **Allow** (see [Permissions](#permissions)).

## Build (from source, for development)

```bash
./build.sh
```

This compiles all Swift sources with `swiftc` (`-warnings-as-errors`, so the
build is warnings-clean by contract), assembles `DarkModeScheduler.app` with a
correct `Info.plist`, and **ad-hoc** code-signs it for local use. It builds a
**universal** (x86_64 + arm64) binary when both slices compile, otherwise the
host architecture only. The script is idempotent and fails loudly
(`set -euo pipefail`).

Output: `./DarkModeScheduler.app` — run it with `open DarkModeScheduler.app`.

> An ad-hoc build runs fine on the machine that built it, but it is **not**
> signed for distribution. To produce a shareable, notarized DMG, use
> [`./release.sh`](#distribution-signed--notarized-release).

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

## Distribution (signed & notarized release)

`release.sh` produces the shippable artifact: a **Developer ID-signed,
Hardened-Runtime, Apple-notarized, stapled** `DarkModeScheduler.app` packaged in
a **drag-to-Applications DMG**. This is what lets a user download it and open it
without Gatekeeper warnings.

```bash
./release.sh
```

### What it does

1. Auto-detects your **Developer ID Application** identity and Team ID.
2. Builds the universal app and signs it with the **Hardened Runtime** and
   [`DarkModeScheduler.entitlements`](DarkModeScheduler.entitlements).
3. **Notarizes the app** and staples the ticket (so it validates even offline).
4. Assembles a signed **DMG** with an `Applications` symlink for drag-install.
5. **Notarizes the DMG** and staples it, then runs a Gatekeeper assessment.

Output: `dist/DarkModeScheduler.dmg` — ready to ship.

### One-time prerequisites

- An **Apple Developer Program** membership and a **Developer ID Application**
  certificate installed in your keychain (create it under
  *developer.apple.com → Certificates*, then double-click to install).
- **Notarization credentials**, stored once as a `notarytool` keychain profile
  using an [app-specific password](https://support.apple.com/102654):

  ```bash
  xcrun notarytool store-credentials "DarkModeScheduler" \
      --apple-id "you@example.com" --team-id "TF2BG2VDPD" \
      --password "abcd-efgh-ijkl-mnop"      # app-specific password
  ```

  Then run: `NOTARY_PROFILE=DarkModeScheduler ./release.sh`
  (or pass `APPLE_ID` + `NOTARY_PASSWORD` + `TEAM_ID` in the environment).

### Hardened Runtime entitlements

The only entitlement is `com.apple.security.automation.apple-events`, which the
Hardened Runtime **requires** for the app to send Apple Events (it drives System
Events to flip Dark/Light). The app is intentionally **not sandboxed** (a
Developer ID app; sandboxing is incompatible with driving System Events), and it
keeps **library validation on** — the private CoreBrightness framework it
`dlopen`s for Night Shift is Apple-signed, so no `disable-library-validation` is
needed.

### Graceful degradation

`release.sh` still works without full setup, and tells you exactly what's
missing:

- **No Developer ID certificate** → it stops with instructions to obtain one.
- **No notarization credentials** (or `SKIP_NOTARIZE=1`) → it builds a
  Developer ID-signed **but un-notarized** DMG for local testing and prints the
  one-time credential-setup command. Such a DMG works on your own machine but
  would show a Gatekeeper warning on someone else's until it is notarized.

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
├── build.sh                 # Compile + bundle + Info.plist + codesign (ad-hoc
│                            #   by default; env-overridable for release signing).
├── release.sh               # Developer ID + Hardened Runtime + notarize +
│                            #   staple → drag-to-Applications DMG.
├── DarkModeScheduler.entitlements  # Hardened Runtime entitlements (automation).
├── run-tests.sh             # Compile + run the unit tests.
├── README.md                # This file.
├── DarkModeScheduler.app    # Build output (created by build.sh).
└── dist/DarkModeScheduler.dmg      # Release output (created by release.sh).
```
