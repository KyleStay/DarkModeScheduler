# Releasing Dark Mode Scheduler

Project Publisher is the only production release and installation route for the
Full channel. It owns the shared Developer ID identity, `StayLevel` notarization
profile, timestamped run folder, provenance manifest, checksums, bounded Apple
service retries, and final artifact verification.

The release contract produces these DMGs:

| Artifact | Executable architecture |
|---|---|
| `DarkModeScheduler-<version>-x86_64.dmg` | Intel |
| `DarkModeScheduler-<version>-arm64.dmg` | Apple silicon |
| `DarkModeScheduler-<version>-universal.dmg` | Intel and Apple silicon |

The App Store channel has a separate local verification path. Do not add App
Store packages or uploads to Project Publisher.

## Prepare and verify

1. Update `VERSION` and `BUILD_NUMBER` near the top of `build.sh` when preparing
   a new version.
2. Review the branch and working tree. Dirty source is supported and recorded in
   the release manifest, but the checkout must remain unchanged for the complete
   release run.
3. Run the repository verification gate:

   ```bash
   make verify-background
   make verify
   ```

## Audit the release contract

Run these commands from Project Publisher:

```bash
cd "/Users/kyle/Documents/Project Publisher"
make audit
swift run project-publisher audit --project darkmode-scheduler
swift run project-publisher doctor
```

`doctor` checks the team `TF2BG2VDPD` Developer ID identities and the existing
`StayLevel` notarytool profile. Do not create replacement project credentials.

## Produce the distribution matrix

From Project Publisher, run:

```bash
swift run -c release project-publisher release --project darkmode-scheduler
```

Project Publisher builds the three declared architectures through
`Scripts/project-publisher-release.sh`, notarizes and staples the apps and DMGs,
checks Gatekeeper acceptance, runs `Scripts/project-publisher-verify.sh`, and
writes one timestamped run beneath its `Releases/` directory.

Success requires all three DMGs plus `manifest.json`, `checksums.txt`, and logs.
The command remains local-only: it does not create tags, upload artifacts, or
publish a GitHub release.

## Install a verified build

Install only through Project Publisher. For a fresh host-native deployment:

```bash
swift run -c release project-publisher install --project darkmode-scheduler --host-only
```

For a complete release followed by installation, omit `--host-only`. To install
an existing run without rebuilding, pass `--from-run <id>`. Project Publisher
quits the running app, swaps the bundle atomically, and verifies the installed
staple, Gatekeeper acceptance, checksum, and architecture.

Do not mount a DMG and copy the app into `/Applications` by hand.

## Failure handling

- Compiler, contract, signing-policy, provenance, and verification failures need
  a source or environment fix. Do not bypass them with the retired standalone
  release script.
- Project Publisher retries only recognized transient Apple timestamp or
  notarization network failures.
- If Apple rejects a submission, inspect the reported submission through the
  shared `StayLevel` profile, fix the cause, and start a fresh Publisher run.
- Keep credentials out of the repository and command arguments. Never inspect,
  print, copy, replace, or store the `StayLevel` secret.
