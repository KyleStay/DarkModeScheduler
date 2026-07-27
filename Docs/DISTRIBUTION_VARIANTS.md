# Full and App Store variants

Dark Mode Scheduler is one product with one shared Swift source tree and two
distribution channels. Do not fork or copy feature code between variants.

| Channel | Build flag | Distribution | Dark appearance | Night Shift |
|---|---|---|---|---|
| Full | none | Project Publisher notarized DMGs | Yes | Yes |
| App Store | `APP_STORE` | Sandboxed App Store candidate | Yes | No |

`DistributionChannel.swift` is the single source of product capability policy.
`Services.swift` is the only compile-time boundary around the private
CoreBrightness implementation. UI and scheduling code query the capability
through `AppModel`; they must not introduce new `#if APP_STORE` branches.

## Build and verify

```bash
make build-full
make build-app-store
make verify-variants
make verify
```

The App Store build is written to
`.build/app-store-product/DarkModeScheduler.app`. Its verification fails if App
Sandbox, network-client, or location access is missing, or if private Night
Shift symbols appear in the executable.

The App Store build deliberately retains Dark/Light automation through System
Events. Its entitlements contain the narrowly scoped
`com.apple.security.temporary-exception.apple-events` value
`com.apple.systemevents`. App Store Connect review notes must explain:

- the user explicitly enables Dark appearance scheduling;
- macOS presents its Automation consent prompt;
- System Events is used only to set the public `dark mode` appearance property;
- no other applications or data are scripted.

Night Shift must remain absent from the App Store executable because macOS has
no public API for controlling it.

## Release ownership

The existing `.project-publisher.json` contract owns only the Full channel:
signed, notarized, stapled, verified `x86_64`, `arm64`, and `universal` DMGs.
Do not add App Store packages, uploads, or credentials to that contract.

`Tools/build-app-store.sh` produces a local sandboxed review candidate. A real
submission additionally needs the App Store record, Mac App Distribution
signing/provisioning, archive validation, metadata, privacy disclosures, and an
explicit upload through Apple tooling. Those external release actions are not
performed by local verification.

## Change checklist

For every product change:

1. Put shared behavior in the normal source files.
2. Put channel policy in `DistributionChannel.swift`.
3. Keep private API code inside the Full-only boundary in `Services.swift`.
4. Make the UI capability-driven so unavailable features disappear cleanly.
5. Run `make verify`; it compiles and checks both channels.

For Full-channel release changes, also follow `AGENTS.md` and run the Project
Publisher audit/release gates.
