# Dark Mode Scheduler

A native macOS **menu bar app** that runs your chosen nighttime effects on a
**sun-based** schedule (computed locally from your location) or at **fixed
times**. Dark appearance and Night Shift are independent: use either one, both,
or neither without surrendering your current appearance choice.

- **Sun times are computed locally** using the NOAA sunrise/sunset algorithm
  (`SunCalculator.swift`). No network is used for sun math.
- **The only outbound network call** is postal-code → latitude/longitude
  geocoding, via the free, key-less [Zippopotam](https://zippopotam.us) API. The
  result is cached; it's only re-fetched when you change the postal code.
- Menu-bar-only (`LSUIElement`) — no Dock icon.
- Swift + SwiftUI `MenuBarExtra`, macOS 13+. **Zero third-party dependencies.**
- One shared source tree produces a **Full** direct-download edition and a
  sandboxed **App Store** edition. The Store edition omits Night Shift because
  macOS exposes no public API for it.

---

## Features

| # | Feature | Summary |
|---|---------|---------|
| 1 | **Start / resume** | Start the next scheduled mode now, then resume the schedule with the same contextual button. When Dark appearance is selected, manual appearance changes are honored until the next boundary. |
| 2 | **Fixed-schedule mode** | Toggle between *Sun-based* and *Fixed times* (pick explicit nighttime/daytime boundaries). All effects share the same phase, wake, and timer logic. |
| 3 | **Sun-time offsets** | Shift the nighttime and daytime boundaries relative to sunset and sunrise by ±180 minutes. |
| 4 | **Optional auto-location** | A "My Location" source uses CoreLocation as an alternative to a manual postal code, with clear inline UI for every authorization state. Postal code stays the default and the fallback; Location Services is entirely optional. |
| 5 | **Non-US locations** | Enter a country code + postal code (e.g. `GB SW1`, `DE 10115`). US 5-digit zips remain the default happy path. Differing response shapes and not-found/offline cases are handled gracefully. |
| 6 | **Transition notifications** (opt-in, default off) | Posts only when a selected effect actually changes; repeated ticks never notify. |
| 7 | **Menu-bar glance** | Surfaces the current phase and next nighttime/daytime boundary, or the pause state. |
| 8 | **Nighttime effects** | Independent **Dark appearance** (default on) and **Night Shift** (default off) controls live in **Right now** with the contextual Start / Resume action. |
| 9 | **Switch early** | Bring the next phase's selected effects forward, hold them until the boundary, then rejoin automatically. Night Shift-only use never requests Appearance Automation permission. |

---

## Requirements

- macOS 13.0 (Ventura) or later.
- The Swift toolchain that ships with the Xcode command-line tools
  (`/usr/bin/swiftc`). No Xcode project, SPM packages, or other installs.

## Install (end users)

Download the DMG for your Mac, double-click it, and **drag the app onto the
Applications folder** shown in the window. Then launch it from Applications — a
sun/moon icon appears in the menu bar; click it to open the popover.

- **`DarkModeScheduler-<version>-arm64.dmg`** — Apple silicon Macs.
- **`DarkModeScheduler-<version>-x86_64.dmg`** — Intel-based Macs.
- **`DarkModeScheduler-<version>-universal.dmg`** — contains both architectures; use this
  when the destination Mac is unknown.

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
correct `Info.plist`, and signs it with Kyle's Developer ID, Hardened Runtime,
the channel-appropriate entitlements, and a secure timestamp. Ad-hoc signing is
prohibited. It builds a **universal** (x86_64 + arm64) binary by default. Set
`BUILD_ARCH=arm64` or `BUILD_ARCH=x86_64` for a single-architecture development
build. The script is idempotent and fails loudly (`set -euo pipefail`).

Output: `./DarkModeScheduler.app` — run it with `open DarkModeScheduler.app`.

Build the sandboxed App Store channel from the same sources:

```bash
make build-app-store
```

Output: `.build/app-store-product/DarkModeScheduler.app`. Run `make verify` to
compile and validate both product channels. See
[`Docs/DISTRIBUTION_VARIANTS.md`](Docs/DISTRIBUTION_VARIANTS.md) for the
capability boundary and Store submission requirements.

> Ordinary builds are signed but not notarized. To produce or install a
> notarized and stapled build, use Project Publisher as described below.

---

## Permissions

The app requests only what a feature needs, and only when that feature is used.

| Permission | When | Required for |
|------------|------|--------------|
| **Automation** (System Events) | First scheduled appearance switch, only when **Dark appearance** is enabled | Live-switching Dark/Light. Night Shift-only schedules never request it. |
| **Location Services** | Only if you pick "My Location" | Feature 4. Fully optional — postal code works without it. |
| **Notifications** | Only if you enable "Notify on transition" | Feature 6. |

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
immediately re-evaluates the current schedule phase and selected effects.

### Location (My Location — optional)

Switch the source to **My Location** to use CoreLocation. The app drives the
authorization flow and shows the current state inline (ask / denied → open
Settings / granted → refresh). If you deny it, postal code remains available.

### Schedule mode & tuning

- Choose **Sun-based** or **Fixed times**, then select independent **Nighttime
  effects** in **Right now**.
- **Dark appearance** defaults on and switches Dark at night / Light during day.
- **Night Shift** defaults off and can run alone. If its guarded private API is
  unavailable, only that control is disabled and the inline explanation remains.
- Sun mode offsets the nighttime/daytime boundaries from sunset/sunrise; fixed
  mode uses explicit start times.

### Start / resume

- **Start nighttime now** (or **daytime**) brings the next scheduled mode forward.
- **Resume schedule** clears the current override and enforces the schedule immediately.
- When Dark appearance is selected, a manual appearance change holds all scheduled
  effects until the next boundary. The same **Resume schedule** button ends that
  hold early. In Night Shift-only mode, Light or Dark appearance is never treated
  as a divergence.

The current override and when it ends are shown in the popover; the state
persists across relaunch.

### Switch early

Tap **Start nighttime now** (or **daytime**) to bring the next
phase forward. Only selected effects change; a Night Shift-only early switch
does not touch appearance or request Automation permission. **Resume schedule**
undoes it, and no transition notification is posted for an early switch.

### Launch at login

Toggle **Launch at Login** in the popover. This uses `SMAppService.mainApp`
(macOS 13+); the toggle reflects the real registration status and surfaces any
error. (macOS may show its own approval UI under System Settings → General →
Login Items.)

---

## How scheduling works

- The schedule is reduced to **day/night phase transitions**. The phase is
  independent of appearance; selected effects map that phase to Dark/Light,
  Night Shift on/off, both, or no system mutation.
- A 60-second `Timer` re-evaluates and enforces. It also re-evaluates
  immediately **on launch**, **on any settings change**, and **on system wake**
  (`NSWorkspace.didWakeNotification`).
- **Idempotent:** AppleScript is issued only for a needed appearance change, and
  Night Shift's guarded live status is compared before mutation. Failed writes
  remain visible and retryable; app-owned warmth cleanup survives relaunch.

### The enforcement state machine

Every evaluation runs through one pure decision (`EnforcementEngine.decide`):

1. **Expire** a due override.
2. **Suspend** while an override is active (accept whatever appearance you've set).
3. If Dark appearance is selected, detect and honor manual appearance divergence.
4. Reconcile each selected and available effect independently.

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
- Reads `supported` and `getBlueLightStatus:` through the same isolated runtime
  adapter, so external drift can be reconciled without redundant writes. A
  failed status read falls back conservatively and never claims a notification
  or ownership without evidence of a real change.
- Only touches Night Shift when you opt in; turning the toggle off restores warm
  mode to off.

**Risk:** because this relies on a private, undocumented interface, a future
macOS release could rename or remove it. If that happens, the toggle will simply
show as unavailable rather than misbehaving. Verified working on macOS 15; the
warm color temperature follows the same day/night phase.

## Distribution (signed & notarized release)

Project Publisher is the only production release and installation route for the
Full channel. It builds Developer ID-signed, Hardened Runtime, notarized, stapled
Intel, Apple silicon, and universal DMGs, then records their source provenance,
checksums, logs, and verification results in one timestamped run folder.

```bash
cd "/Users/kyle/Documents/Project Publisher"
swift run project-publisher audit --project darkmode-scheduler
swift run project-publisher doctor
swift run -c release project-publisher release --project darkmode-scheduler
```

The repository does not contain a second notarization pipeline. See the
[release runbook](Docs/RELEASING.md) for the full audit, credential, release,
and installation procedure.

### What it does

1. Audits the registered `.project-publisher.json` contract and captures the
   branch, commit, dirty state, and source inventory.
2. Passes the exact declared architecture list and shared Developer ID identity
   into the repository-owned build adapter.
3. Notarizes, staples, and verifies each app and DMG, including Gatekeeper and
   project-specific artifact checks.
4. Writes the artifacts, `manifest.json`, `checksums.txt`, and logs beneath one
   Project Publisher `Releases/<timestamp>/darkmode-scheduler/<version>/` folder.

Outputs, ready to ship:

- `DarkModeScheduler-<version>-x86_64.dmg`
- `DarkModeScheduler-<version>-arm64.dmg`
- `DarkModeScheduler-<version>-universal.dmg`

### Signing prerequisites

Releases reuse team `TF2BG2VDPD`'s installed Developer ID identity and the
team-wide `StayLevel` notarytool keychain profile. Do not create replacement
project credentials. Run Project Publisher's doctor command if either shared
prerequisite is unavailable, then release through Project Publisher as described
in [`Docs/RELEASING.md`](Docs/RELEASING.md).

### Hardened Runtime entitlements

The only entitlement is `com.apple.security.automation.apple-events`, which the
Hardened Runtime **requires** for the app to send Apple Events (it drives System
Events to flip Dark/Light). The app is intentionally **not sandboxed** (a
Developer ID app; sandboxing is incompatible with driving System Events), and it
keeps **library validation on** — the private CoreBrightness framework it
`dlopen`s for Night Shift is Apple-signed, so no `disable-library-validation` is
needed.

### Failure behavior and local-test builds

Production releases stop on credential, compiler, signing-policy, provenance,
artifact-matrix, notarization, or verification failures. Project Publisher
retries only recognized transient Apple-service failures. Ordinary `build.sh`
products remain signed but unnotarized development builds; the repository no
longer exposes a second DMG release path for them.

---

## Developer notes

### Run the unit tests (no GUI required)

```bash
./run-tests.sh
```

`SunCalculatorTests.swift` is a self-contained assertion runner (its own `@main`,
not an XCTest bundle). It checks computed sunrise/sunset against **U.S. Naval
Observatory** reference values (±2 min), plus DST-awareness and polar edge cases,
**and** the scheduling core: phase boundaries, all four effect combinations,
migration defaults, manual divergence, pause/resume/expiry, switch-early, wake
reconciliation, Night Shift unavailability/failure retry, and idempotency. It
also compiles `Support.swift` to test the isolated settings migration.

### Background-safe verification

```bash
make verify-background
```

This is the default packaged UI verification lane and is safe to run without
activating the app or changing user/system state. It runs the static
focus-safety boundary check, builds a signed fixture app, and invokes:

```bash
./.build/background-fixture-product/DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler \
  --background-fixture --output .build/background-verification
```

The fixture never activates an app, creates a menu-bar item, orders a window,
posts global events, requests TCC permissions, changes login items or system
defaults, or calls live appearance/Night Shift adapters. The required signed
build may contact Apple's timestamp service; this is build infrastructure, not
the fixture process and is not a claim of offline operation.
It uses synthetic location/schedule data, an isolated UserDefaults suite, and
in-memory adapters, then renders the real `PopoverView` offscreen into
`.build/background-verification/active-night.png` and `paused-day.png` plus
`report.json`. These artifacts are local verification output, not user data.

`make verify` includes `make verify-background` after the pure tests, universal
Full build, and distribution-variant checks.

### Pure self-test (`--selftest`)

```bash
./DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler --selftest
```

Runs only the scheduling and state-machine checks without launching the GUI or
touching live system state: offsets, fixed-mode boundaries, next-transition,
override expiry, and the divergence/suspend/enforce decisions.

### Opt-in interactive self-test (`--interactive-selftest`)

```bash
./DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler --interactive-selftest
```

This is intentionally excluded from `make verify`. It forces a real appearance
switch through System Events, verifies the live `AppleInterfaceStyle`, checks
idempotency, and restores the original appearance. It requires Automation
permission and a human-controlled interactive session; run it only when live
WindowServer, permission, and system-state behavior is explicitly in scope.

See [`Docs/VERIFICATION.md`](Docs/VERIFICATION.md) for the full lane boundary
and the remaining manual/live QA checklist.

## File tree

```
Darkmode scheduler/
├── main.swift               # SwiftUI App/Scene, verification lanes, dispatch.
├── AppModel.swift           # @MainActor orchestrator: timer, wake, tick,
│                            #   applies EnforcementEngine decisions, persistence.
├── PopoverView.swift        # The MenuBarExtra popover UI (all 9 features).
├── Services.swift           # AppearanceController, GeocodeService (intl),
│                            #   LocationService (CoreLocation), NotificationService,
│                            #   NightShiftController (private CBBlueLightClient).
├── Support.swift            # Logging, ResolvedLocation (+v1 migration), errors,
│                            #   SettingsStore (UserDefaults).
├── Scheduler.swift          # PURE core: SchedulePhase/Effects, transitions,
│                            #   Scheduler, Override, EnforcementEngine.
├── SunCalculator.swift      # Pure NOAA sunrise/sunset math (shared with tests).
├── SunCalculatorTests.swift # Standalone, GUI-free unit tests (@main runner).
├── BackgroundVerification.swift # Isolated offscreen SwiftUI fixture + JSON/PNGs.
├── build.sh                 # Compile + bundle + Info.plist + Developer ID
│                            #   signing; ad-hoc output is prohibited.
├── Makefile                 # Background-safe tests and signed builds.
├── Docs/RELEASING.md        # Project Publisher release/install checklist.
├── DarkModeScheduler.entitlements  # Hardened Runtime entitlements (automation).
├── run-tests.sh             # Compile + run the unit tests.
├── Tools/check-background-test-safety.sh # Static focus/side-effect boundary.
├── Tools/verify-background.sh # Packaged background-safe fixture verification.
├── Docs/VERIFICATION.md     # Safe/default and opt-in interactive QA contracts.
├── README.md                # This file.
└── DarkModeScheduler.app    # Build output (created by build.sh).
```
