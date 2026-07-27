# Project Agent Guidance

## Project Publisher Releases

Preserve this repository's `.project-publisher.json` contract and its Project
Publisher adapter. Distribution readiness means signed, notarized, stapled, and
verified DMG installers for `x86_64`, `arm64`, and `universal`. Do not add PKG
unless a future system-level installation requirement is documented.

Audit or release through `/Users/kyle/Documents/Project Publisher`; do not
replace the adapter with an unrelated release path. Keep project-specific
entitlements, nested-code signing, helpers, extensions, drivers, and payload
verification here. Dirty checkouts are allowed and must be recorded accurately
in the timestamped manifest. The local release command must not create tags,
upload artifacts, or publish a GitHub release.

Never produce or install an ad-hoc-signed app. Every `.app` bundle created by
the project, including ordinary development and verification builds, must use
`Developer ID Application: Kyle Stay (TF2BG2VDPD)`, Hardened Runtime, the
channel-appropriate entitlements, and a secure timestamp. A local build may
remain unnotarized, but it must still be fully signed; distributable and
installed builds must go through Project Publisher and be notarized, stapled,
and Gatekeeper-verified. Do not pass `CODESIGN_IDENTITY=-`, strip a signature,
or add an unsigned/ad-hoc fallback when signing is unavailable—fail the build
and fix the signing environment.

Install this app locally through Project Publisher rather than mounting the DMG
or dragging into `/Applications` by hand. `project-publisher install --project
darkmode-scheduler` runs a fresh release and then installs the build for this Mac — the native
`arm64`/`x86_64` slice, falling back to `universal` — into `/Applications`,
quitting any running instance, swapping the bundle atomically, and verifying the
installed copy's staple, Gatekeeper acceptance, and architecture. `--from-run
<id>` installs a prior run without rebuilding; `--dry-run` previews the selection
and target. An app that refuses to quit is reported and skipped, never clobbered.


### Compatibility invariants

- Treat `.project-publisher.json`, the project-owned adapter and verification command, and this section as one release API. Update them together whenever architectures, versioning, signing, entitlements, nested code, helpers, extensions, installer payloads, or packaging change.
- The adapter must consume Project Publisher's supplied environment and write exactly the declared filenames and formats. Do not create extra installers or silently omit a declared architecture.
- One Publisher invocation owns one timestamped run folder. Success requires every declared artifact plus `manifest.json`, `checksums.txt`, and logs in that folder.
- Dirty input, including intentionally deleted tracked files, is supported. Keep the checkout unchanged from the initial provenance snapshot through final verification; do not edit source or run source-mutating agents concurrently with a release.
- Use Project Publisher's two-job default and bounded transient-Apple-service retries. Compiler, contract, signing-policy, provenance, and verification failures require a real fix rather than more concurrency or broad retries.
- After release-affecting changes, run the project verification command and Project Publisher audit. Complete a real focused notarized release after changes to signing order, entitlements, nested code, helpers, extensions, drivers, DMG layout, or PKG payloads.
- Reuse team `TF2BG2VDPD` signing identities and the `StayLevel` notarytool profile. Never create replacement credentials or read, print, copy, or store credential secrets.
- Preserve the no-ad-hoc invariant in `build.sh`, the Project Publisher adapter,
  verification commands, and documentation whenever build or signing behavior changes.

Preserve unrelated dirty work. Read the README, build scripts, tests, and nearby
documentation before changing behavior. Run the smallest useful project test
and architecture build after code or packaging changes.

## Shared Full and App Store product

Maintain one shared Swift source tree for both channels. Read
`Docs/DISTRIBUTION_VARIANTS.md` before changing product capabilities, build
flags, entitlements, or distribution behavior.

- The normal build is the Full channel. It retains Night Shift and is the only
  channel owned by `.project-publisher.json` and Project Publisher.
- The App Store channel is selected only with `APP_STORE` through
  `DISTRIBUTION_CHANNEL=app-store`. It must be sandboxed and must never contain
  CoreBrightness, `CBBlueLightClient`, or any other private API.
- Centralize channel policy in `DistributionChannel.swift`. Keep the private
  implementation boundary in `Services.swift`; do not scatter new
  `#if APP_STORE` checks through model or UI code.
- Keep shared features and UI shared. Query capabilities through `AppModel` so
  unavailable controls disappear cleanly.
- Do not add App Store packaging, uploads, credentials, or artifacts to the
  Project Publisher contract. The Store candidate has a separate local build
  and verification path.
- After any app change, run `make verify`. Its variant gate must compile both
  channels, confirm Full still contains its intentional Night Shift adapter,
  confirm the Store build is sandboxed, and reject private Night Shift symbols
  in the Store executable.
