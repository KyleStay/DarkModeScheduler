# Releasing Dark Mode Scheduler

This runbook produces three distribution installers:

| Installer | Executable architecture | Use when |
|---|---|---|
| `DarkModeScheduler-Intel.dmg` | `x86_64` | The destination is an Intel Mac |
| `DarkModeScheduler-Apple-Silicon.dmg` | `arm64` | The destination is an M-series Mac |
| `DarkModeScheduler-Universal.dmg` | `x86_64 arm64` | The destination architecture is unknown |

Every production installer is Developer ID signed with Hardened Runtime,
notarized by Apple, stapled for offline validation, checked by Gatekeeper, and
listed in `dist/SHA256SUMS.txt`.

## Shared signing environment

Project Publisher owns the release credentials for team `TF2BG2VDPD`:

- `Developer ID Application: Kyle Stay (TF2BG2VDPD)`
- notarytool keychain profile `StayLevel`

Do not create replacement credentials for this project. Diagnose the shared
environment from `/Users/kyle/Documents/Project Publisher`:

```sh
swift run project-publisher doctor
```

## Production release

### 1. Prepare the version

1. Update `VERSION` and `BUILD_NUMBER` near the top of `build.sh`.
2. Ensure the build number is greater than the previous distributed build.
3. Review the current branch and working tree so the intended source is being
   released.

### 2. Run verification

```bash
make verify
```

This runs the pure test suite and verifies that a Universal app can be built
with both CPU slices.

### 3. Produce all installers

```bash
make release
```

The release script performs these checks automatically:

1. Confirms required macOS command-line tools and entitlements exist.
2. Resolves the Developer ID identity and Team ID.
3. Validates the saved notary profile before compiling anything.
4. Builds and verifies the exact architecture for each app.
5. Signs, notarizes, and staples each app.
6. Creates, signs, verifies, notarizes, and staples each DMG.
7. Requires Gatekeeper acceptance for both the app and DMG.
8. Publishes all requested DMGs atomically, preserving the previous release if
   any earlier step fails.
9. Writes SHA-256 checksums to `dist/SHA256SUMS.txt`.

Notarization makes several Apple submissions and can take several minutes.

### 4. Confirm the output

```bash
(cd dist && shasum -a 256 -c SHA256SUMS.txt)
xcrun stapler validate dist/DarkModeScheduler-Intel.dmg
xcrun stapler validate dist/DarkModeScheduler-Apple-Silicon.dmg
xcrun stapler validate dist/DarkModeScheduler-Universal.dmg
```

Only DMGs without `-Unnotarized` in the filename are distribution candidates.

### 5. Smoke-test on clean Macs

Before broad distribution:

1. Test the Intel installer on an Intel Mac, if one is available.
2. Test the Apple Silicon installer on an M-series Mac.
3. Open the DMG, drag the app to Applications, and launch it normally.
4. Confirm there is no Gatekeeper warning.
5. Confirm the menu-bar app launches and the first appearance switch presents
   the expected Automation permission request.

## Focused and local-test commands

Produce one fully notarized architecture when needed:

```bash
make release-intel
make release-apple-silicon
make release-universal
```

Produce explicitly unnotarized local-test installers:

```bash
make release-local
```

Local-test filenames include `-Unnotarized` and must not be shared as normal
downloads.

To use a differently named notary profile:

```bash
make release NOTARY_PROFILE="AnotherProfile"
```

## Failure and recovery

- Credential, certificate, tool, or architecture configuration errors stop in
  preflight before the production build starts.
- Temporary app archives, staging directories, and DMGs are removed on exit.
- Production filenames are replaced only after every requested variant passes
  signing, notarization, stapling, disk-image verification, and Gatekeeper.
- A failed run therefore leaves the last complete production release intact.
- If Apple rejects a submission, inspect it with:

  ```bash
  xcrun notarytool log SUBMISSION_ID \
    --keychain-profile "StayLevel"
  ```

  Fix the reported signing or packaging issue and rerun `make release`.

## Security notes

- Never commit an Apple ID, app-specific password, exported certificate, API
  key, or keychain file.
- Prefer the keychain profile over environment variables because secrets do not
  appear in shell history or process arguments.
- Do not distribute `-Unnotarized` artifacts.
- Share `SHA256SUMS.txt` alongside public downloads when recipients need an
  integrity check.
