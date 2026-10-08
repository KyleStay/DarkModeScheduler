# Verification lanes

The default verification contract is background-safe. It is suitable for CI,
an unattended agent, or a developer working in another app. It does not claim
to verify WindowServer behavior that inherently requires a real menu bar,
popover, permissions, or global shortcuts.

## Default commands

Run the pure model and migration checks:

```bash
./run-tests.sh
```

Run the static boundary plus the packaged offscreen UI fixture:

```bash
make verify-background
```

Run the complete default gate:

```bash
make verify
```

`verify-background` builds a signed native-architecture app in
`.build/background-fixture-product/`, then runs its `--background-fixture`
entry point with an isolated, process-specific UserDefaults suite. The fixture
uses deterministic synthetic schedule/location data and in-memory appearance
and Night Shift adapters. It does not start the live model timer or wake/time
observers. It renders the actual `PopoverView` via `NSHostingView` without
creating `MenuBarExtra` or `NSStatusItem`, and writes:

- `.build/background-verification/report.json`
- `.build/background-verification/active-night.png`
- `.build/background-verification/paused-day.png`

The static check in `Tools/check-background-test-safety.sh` guards the fixture
and default scripts against activation, window ordering, global events, status
items/menu-bar scenes, AppleScript, permissions, login-item changes, and
`UserDefaults.standard` access. It also asserts that the fixture's transitive
model/service boundary uses the disabled CoreLocation adapter. The signed build
may contact Apple's timestamp service as required by the project signing
policy; the fixture process itself does not use the network. The real app source
still has those APIs because the product needs them interactively; they are
outside this lane's boundary.

## Explicitly interactive lane

Only run this when live system behavior is intentionally in scope:

```bash
./DarkModeScheduler.app/Contents/MacOS/DarkModeScheduler --interactive-selftest
```

This switches the actual appearance through System Events, requires Automation
permission, and restores the original mode. It is not part of `make verify`.

Remaining manual/live QA includes the real `MenuBarExtra` placement and
popover behavior, menu-bar/window focus, global shortcut or event behavior if
added later, Automation and Location Services permission prompts, Launch at
Login registration, notification delivery, CoreBrightness Night Shift
behavior, sleep/wake transitions, and Gatekeeper/notarized release testing.

Do not use background verification to change real Night Shift or dark-mode
state. If a live check is needed, run it explicitly and record the state that
was changed and restored.

## Menu-bar disappearance across displays and Spaces

The app declares one unconditional `MenuBarExtra` scene with window style in
`main.swift`, with an app-owned `@StateObject` model and a system-symbol label
(`sun.max` or `moon.stars`). There is no app-controlled insertion binding,
custom status-item image cache, fixed label color, or display-dependent label
visibility. The former screen-under-mouse lookup in `PopoverView.swift` budgeted only
the popover height; the host-sizing correction below replaces it. These source facts do not establish live visibility after
a display or Space transition; the background fixture does not create the
real menu-bar scene.

For an explicitly authorized live reproduction, record the macOS version,
app version, display resolutions/scales, current "Displays have separate
Spaces" setting, and any menu-bar manager. Without changing appearance,
permissions, or display settings:

1. Identify whether the newly active menu bar, the dimmed menu bar, or both lose
   the icon after clicking a window on the other display.
2. Distinguish a missing item from a blank but clickable item, and record
   whether the app process remains running. Note whether neighboring icons
   disappear too and whether the bar has room for the item.
3. Check opening/closing the popover on each display and switching an existing
   Space. Record the exact transition that first triggers the loss and whether
   returning to the previous display/Space restores it.

A confirmed affected app and this transition/visibility evidence are needed
before choosing a refresh or presentation fix. The interactive appearance
self-test does not reproduce this issue and should not be used for it.


## Host sizing correction and synthetic presentation diagnostic

`PopoverView` now measures the visible height of its actual hosting window's
screen, rather than the screen under the pointer. The old lookup could size a
popover for a different monitor, and was not invalidated when the host moved.
`PresentationHostView` detaches the old window's observers, follows the current
window, and coalesces screen, backing-scale, effective-appearance, Space and
screen-parameter callbacks. It updates only the presentation budget, without a
scheduler tick, settings write, data poll or identity reset. Very short work
areas are no longer forced to a 320-point minimum.

The symbol remains an untinted system image owned by the unconditional SwiftUI
scene. There is no demonstrated production source cause for the disappearing
icon or incorrect native contrast, and this sizing fix does **not** claim to
resolve those symptoms. SwiftUI owns native status-item lifetime, native label
conversion, highlight tint, click dispatch and anchoring. No private access,
forced insertion, status-item replacement or speculative repaint is added.

Run the explicit interactive reproduction from the repository root:

```bash
Tools/menu-bar-diagnostic.sh --duration 30
Tools/menu-bar-diagnostic.sh --night --duration 30
Tools/menu-bar-diagnostic.sh --cycle --duration 30
```

Omit `--duration` to keep it running; use Ctrl-C or its **Quit** button to stop.
This builds a Developer ID signed local diagnostic and creates one temporary
real `MenuBarExtra(.window)` using the **same symbol view** as production.
It uses isolated defaults, two synthetic models, disabled settings controls,
no live model timer, no geocoding and no appearance/Night Shift/login/permission
operations. The installed app stays running, so identify this temporary item by
its **Synthetic presentation diagnostic** header. `--cycle` alternates the
model snapshot every half-second; it does not poll or change system state.
The regular app and `make verify` do not start this lane.

Outputs are under `.build/menu-bar-diagnostic/`:

- `events.ndjson`: startup, insertion, phase, Space, display, wake, focus and
  native-window changes, including phase and PID. Popover host events identify
  its screen, backing scale, appearance and geometry.
- `button-<sequence>-<index>.png`: AppKit's rendering of this process's own
  native status button where public enumeration makes that button available.
  No other app or desktop pixels are captured.

Use the **Sample** button before/after a transition. If the item disappears,
run `kill -USR1 <diagnostic-pid>` from another terminal to sample it without a
click. The PID is in each JSON record. `nativeButtonCount`, button bounds,
`windowVisible`, `visibleRect`, screen intersection, image template/size/reps,
highlight/background style, accessibility-label presence and retained
action/target separate observable host/content failures. Compare the image to
the phase in the record. `previous-native-button-missing` means a previously
observed native host is no longer publicly enumerable; `zero-width` and
`outside-screen-candidate` identify geometry failures. A present, clickable host
with a blank capture points toward content rendering. The label has no text
by design; `titlePresent: false` alone is not a failure.

Public SwiftUI APIs do not expose its underlying `NSStatusItem.isVisible` or
`length`; these are reported as unavailable, with button bounds as evidence.
`native-host-not-yet-observed` is inconclusive, not proof of a missing scene.
Offscreen button captures cannot establish WindowServer mirroring, actual
on-screen contrast, menu-bar-manager overflow or native clicks. `sceneInserted`
is the diagnostic binding's state, not a guarantee of visibility. The diagnostic
never forces it back to true after intentional hiding.

The offscreen renderer keeps the CLI main thread for AppKit (rather than
calling `dispatchMain()`), uses never-ordered borderless hosts, and lets their
layout transactions settle before capture. Popover fixtures use an explicit
synthetic height and light appearance with a white background; their observer
bridge is exercised separately with never-shown windows. Pixel sampling covers
the actual backing bitmap, and PNG dimensions in the report are physical pixels.
The blank-content gate counts ink against that known white background, so a
blank white image cannot pass it.

The background gate additionally exercises 12 A/B host migrations, old-host
observer detachment, rapid backing/appearance/Space callbacks, teardown and
short-host fitting. It renders both shared glyphs in light/dark at 1x/2x with
pixel visibility/contrast assertions, plus both real popovers in a 500-point
synthetic work area. Inspect `glyph-*.png` and `*-short-host.png` alongside the
existing fixtures. This does not verify native highlighted status-bar tint;
inspect the real button capture and click path in the interactive lane.

Remaining live matrix: A→B→A focus on active and dimmed bars, 1x/2x displays,
different wallpaper luminance, existing Spaces/fullscreen and return, and
wake/reconnect. Record clickability, popup host screen, normal and highlighted
pixels, and neighboring-item overflow. Do not change global display settings
or actual appearance to perform this check.


Diagnostic implementation note: insertion is scene `@State` with guarded
write-back, rather than a published model field. The first diagnostic stalled in SwiftUI graph updates. Guarding equal
insertion write-backs avoids recursively invalidating the scene; six-second
cycles then completed with 16 public-state samples, both with and without
native-button capture.
The regular production scene still uses its original unconditional insertion.


### Verified scope of this change

The focused background fixture rendered four real-popover PNGs and eight shared
glyph PNGs; all were visually inspected. Two six-second synthetic live runs
completed phase cycling and timed shutdown, with 16 samples each. The capture
run retained a nonzero native button, template image, and target/action across
the samples; its PNGs visibly matched the recorded day/night phase. This was a
startup/cycling smoke test, not a monitor/Space migration or native-click test.
No highlighted/dimmed-bar, wallpaper, fullscreen, reconnect or wake matrix was
performed, and no actual system appearance or Night Shift was changed.

Source verification does not establish installed-app provenance. Inspect the
running executable path and compare installed/source executables separately.
Validate signatures with normal certificate/keychain access: restricted-shell
certificate failures can misleadingly report an invalid signature. Local
verification does not install the app; installation remains a Project Publisher
workflow.
