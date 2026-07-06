# Dark Mode Scheduler

A native macOS **menu bar app** that automatically switches the system
appearance to **Dark at sunset** and **Light at sunrise**, based on a **US
zipcode** you enter. It's the manual, zipcode-driven alternative to macOS's
built-in Location-Services "Auto" appearance — useful if you keep Location
Services off but still want automatic day/night theming.

- **Sun times are computed locally** using the NOAA sunrise/sunset algorithm
  (`SunCalculator.swift`). No network is used for sun math.
- **The only network call** is zipcode → latitude/longitude geocoding, via the
  free, key-less [Zippopotam](https://zippopotam.us) API. The result is cached;
  it's only re-fetched when you change the zipcode.
- Menu-bar-only (`LSUIElement`) — no Dock icon.
- Swift + SwiftUI `MenuBarExtra`, macOS 13+. **Zero third-party dependencies.**

---

## Requirements

- macOS 13.0 (Ventura) or later.
- The Swift toolchain that ships with the Xcode command-line tools
  (`/usr/bin/swiftc`). No Xcode project, SPM packages, or other installs.

## Build

```bash
./build.sh
```

This compiles `main.swift` + `SunCalculator.swift` with `swiftc`
(`-warnings-as-errors`, so the build is warnings-clean by contract), assembles
`DarkModeScheduler.app` with a correct `Info.plist`, and ad-hoc code-signs it
(`codesign -s - --deep`). It builds a **universal** (x86_64 + arm64) binary when
both slices compile, otherwise the host architecture only. The script is
idempotent and fails loudly (`set -euo pipefail`).

Output: `./DarkModeScheduler.app`

## Run

```bash
open DarkModeScheduler.app
```

A sun/moon icon appears in the menu bar. Click it to open the popover.

## First run — Automation permission (important)

To live-switch the system appearance, the app tells **System Events** to toggle
Dark Mode via AppleScript. The **first time** it does this, macOS shows an
**Automation** permission prompt:

> "Dark Mode Scheduler" wants access to control "System Events".

Click **OK / Allow**. If you dismiss it, the popover shows an inline hint and you
can grant access later at:

**System Settings → Privacy & Security → Automation → Dark Mode Scheduler →
enable "System Events".**

Until this is granted, the app cannot change the appearance (it logs the
`-1743` / `errAEEventNotPermitted` error and surfaces the hint instead of
crashing or spinning).

## Set / change your zipcode

Open the popover, type a 5-digit US zipcode into the **Zipcode** field, and press
**Save** (or Return). The app geocodes it once, caches
`{zip, lat, lon, city, state}`, shows the resolved **city/state**, today's
**sunrise** and **sunset**, and the **current mode** vs. the scheduled mode.
Invalid zip, zip-not-found, and offline errors are shown inline. Changing the
zipcode immediately re-evaluates and enforces the correct appearance.

## Launch at login

Toggle **Launch at Login** in the popover. This uses `SMAppService.mainApp`
(macOS 13+); the toggle reflects the real registration status and surfaces any
registration error. (For login items, macOS may show its own approval UI under
System Settings → General → Login Items.)

## How scheduling works

- Desired mode = **Dark** if `now ≥ today's sunset` **or** `now < today's
  sunrise`, else **Light**.
- A 60-second `Timer` recomputes and enforces the mode. It also re-evaluates
  immediately **on launch**, **on zipcode change**, and **on system wake**
  (`NSWorkspace.didWakeNotification`).
- **Idempotent:** the AppleScript switch is issued **only** when the live
  appearance differs from the desired one — no redundant calls, no flicker.

## Known limitation (v1)

The app **enforces** the schedule. If you manually flip the appearance (e.g. via
Control Center) while the schedule says otherwise, it will be **corrected on the
next 60-second tick**. There is intentionally **no pause/override** in v1. If you
want to keep a manual choice, quit the app (menu bar → **Quit**).

---

## Developer notes

### Run the unit tests (no GUI required)

```bash
./run-tests.sh
```

`SunCalculatorTests.swift` is a self-contained assertion runner (its own `@main`,
not an XCTest bundle). It checks computed sunrise/sunset against **U.S. Naval
Observatory** reference values for New York, Los Angeles, and Chicago to within
**±2 minutes**, plus DST-awareness, day-length sanity, and polar edge cases. It
exits non-zero if any assertion fails.

### Hidden self-test (`--selftest`)

The executable has a hidden CLI flag used for headless verification. It is **not**
on the normal user path (the GUI never triggers it):

```bash
./DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler --selftest
```

It: (1) records the current appearance; (2) forces the opposite mode and verifies
the live `AppleInterfaceStyle` actually changed; (3) enforces the same mode again
and confirms **no AppleScript is issued** (idempotency); (4) restores the original
appearance. It prints, per step, whether AppleScript was issued, and exits 0 on
success. If Automation permission hasn't been granted yet, it reports the `-1743`
condition and what to click — it cannot complete headlessly until a human grants
that permission once.

## File tree

```
Darkmode scheduler/
├── main.swift               # Entire app: model, geocoding, appearance control,
│                            #   scheduler, MenuBarExtra UI, --selftest.
├── SunCalculator.swift      # Pure NOAA sunrise/sunset math (shared with tests).
├── SunCalculatorTests.swift # Standalone, GUI-free unit tests (@main runner).
├── build.sh                 # Compile + bundle + Info.plist + ad-hoc codesign.
├── run-tests.sh             # Compile + run the unit tests.
├── README.md                # This file.
└── DarkModeScheduler.app    # Build output (created by build.sh).
```
