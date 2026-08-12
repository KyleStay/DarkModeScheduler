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
