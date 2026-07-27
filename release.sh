#!/usr/bin/env bash
#
# Production release pipeline for Dark Mode Scheduler.
#
# Produces Intel, Apple Silicon, and Universal Developer ID-signed,
# Hardened-Runtime, notarized + stapled apps packaged in drag-to-Applications
# DMGs. Gatekeeper opens them with no scary warnings.
#
# Stages:
#   1. Resolve the Developer ID signing identity + Team ID.
#   2. For each requested architecture, build + sign the app.
#   3. Verify and notarize the app, then staple it for offline validation.
#   4. Assemble and sign its architecture-labelled DMG.
#   5. Notarize and staple the DMG.
#   6. Run final Gatekeeper assessments.
#
# Notarization reuses the team-wide StayLevel keychain profile managed by
# Project Publisher. Do not create replacement credentials for this project.
#
# Config (all env-overridable):
#   SIGN_IDENTITY   signing identity (default: first "Developer ID Application")
#   TEAM_ID         Apple Team ID (default: derived from the identity)
#   NOTARY_PROFILE  notarytool keychain profile name  (preferred)
#   APPLE_ID + NOTARY_PASSWORD  alternative to NOTARY_PROFILE (app-specific pwd)
#   SKIP_NOTARIZE   non-empty → build + sign + DMG only (local test build)
#   RELEASE_ARCHS   space-separated subset of: x86_64 arm64 universal
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DarkModeScheduler"
DISPLAY_NAME="Dark Mode Scheduler"
APP_BUNDLE="${APP_NAME}.app"
ENTITLEMENTS="${APP_NAME}.entitlements"
DIST_DIR="dist"
RELEASE_ARCHS="${RELEASE_ARCHS:-x86_64 arm64 universal}"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-StayLevel}"
APPLE_ID="${APPLE_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠️  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

APP_ZIP=""
STAGING=""
CHECKSUMS_TMP=""
TEMP_DMGS=()
FINAL_DMGS=()

cleanup() {
    local status=$?
    trap - EXIT
    set +u
    [ -z "$APP_ZIP" ] || rm -f "$APP_ZIP" || true
    [ -z "$STAGING" ] || rm -rf "$STAGING" || true
    [ -z "$CHECKSUMS_TMP" ] || rm -f "$CHECKSUMS_TMP" || true
    for path in "${TEMP_DMGS[@]}"; do
        [ ! -e "$path" ] || rm -f "$path" || true
    done
    exit "$status"
}
trap cleanup EXIT

# Submit a path to the notary service using whichever credentials are configured.
notarize() {
    local path="$1"
    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit "$path" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$path" \
            --apple-id "$APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM_ID" --wait
    fi
}

validate_notary_credentials() {
    log "Validating Apple notarization credentials…"
    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null || die \
"Notarization profile '$NOTARY_PROFILE' is missing or invalid.

 Run Project Publisher's doctor command to diagnose the shared StayLevel
 signing environment. Do not create replacement project credentials.

 See Docs/RELEASING.md for the canonical release route."
    elif [ -n "$APPLE_ID" ] && [ -n "$NOTARY_PASSWORD" ]; then
        xcrun notarytool history \
            --apple-id "$APPLE_ID" --password "$NOTARY_PASSWORD" \
            --team-id "$TEAM_ID" >/dev/null || die "Apple notarization credentials are invalid."
    else
        die "Notarization credentials are incomplete. See Docs/RELEASING.md."
    fi
}

# --- 1. Preflight signing, tooling, architectures, and notarization ----------
for tool in security codesign lipo hdiutil spctl xcrun shasum; do
    command -v "$tool" >/dev/null || die "Required release tool '$tool' was not found."
done
[ -x /usr/bin/swiftc ] || die "Swift compiler not found at /usr/bin/swiftc."
[ -f "$ENTITLEMENTS" ] || die "Missing $ENTITLEMENTS"

ARCH_COUNT=0
for arch in $RELEASE_ARCHS; do
    ARCH_COUNT=$((ARCH_COUNT + 1))
    case "$arch" in
        x86_64|arm64|universal) ;;
        *) die "Unsupported architecture '$arch' in RELEASE_ARCHS." ;;
    esac
done
[ "$ARCH_COUNT" -gt 0 ] || die "RELEASE_ARCHS must contain at least one architecture."

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
[ -n "$SIGN_IDENTITY" ] || die \
"No 'Developer ID Application' identity found in your keychain.

 Distribution requires an Apple Developer Program membership (\$99/yr) and a
 Developer ID Application certificate. Create one at
 https://developer.apple.com/account/resources/certificates, download and
 double-click it to install, then re-run. (Or set SIGN_IDENTITY explicitly.)"

if [ -z "$TEAM_ID" ]; then
    TEAM_ID="$(printf '%s' "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
fi
[ -n "$TEAM_ID" ] || die "Could not derive Team ID from '$SIGN_IDENTITY'; set TEAM_ID."

log "Signing identity : $SIGN_IDENTITY"
log "Team ID          : $TEAM_ID"

mkdir -p "$DIST_DIR"

NOTARIZED=1
if [ -n "$SKIP_NOTARIZE" ]; then
    NOTARIZED=0
    warn "SKIP_NOTARIZE set — building signed but UN-notarized DMGs (local test only)."
else
    validate_notary_credentials
fi

# --- 2-6. Build, verify, notarize, and package each architecture ------------
for arch in $RELEASE_ARCHS; do
    case "$arch" in
        x86_64) label="Intel" ;;
        arm64) label="Apple-Silicon" ;;
        universal) label="Universal" ;;
        *) die "Internal error: architecture '$arch' passed preflight." ;;
    esac

    ARTIFACT_SUFFIX=""
    [ "$NOTARIZED" = 1 ] || ARTIFACT_SUFFIX="-Unnotarized"
    FINAL_DMG_PATH="${DIST_DIR}/${APP_NAME}-${label}${ARTIFACT_SUFFIX}.dmg"
    TEMP_DMG_PATH="${DIST_DIR}/.${APP_NAME}-${label}.dmg"
    rm -f "$TEMP_DMG_PATH"
    TEMP_DMGS+=("$TEMP_DMG_PATH")
    FINAL_DMGS+=("$FINAL_DMG_PATH")

    log "Building ${label} app, signed with Developer ID + Hardened Runtime…"
    BUILD_ARCH="$arch" \
    CODESIGN_IDENTITY="$SIGN_IDENTITY" \
    CODESIGN_ENTITLEMENTS="$ENTITLEMENTS" \
    CODESIGN_RUNTIME=1 \
        ./build.sh

    log "Verifying ${label} app signature and architecture…"
    codesign --verify --strict --verbose=2 "$APP_BUNDLE"
    codesign -dvv "$APP_BUNDLE" 2>&1 | grep -Ei "Authority|TeamIdentifier|Runtime|flags=" || true
    APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
    if [ "$arch" = "universal" ]; then
        lipo "$APP_BINARY" -verify_arch x86_64 arm64
    elif [ "$(lipo -archs "$APP_BINARY")" != "$arch" ]; then
        die "${label} app has unexpected architecture: $(lipo -archs "$APP_BINARY")"
    fi
    echo "   Architectures: $(lipo -archs "$APP_BINARY")"

    if [ "$NOTARIZED" = 1 ]; then
        log "Notarizing ${label} app (this can take a few minutes)…"
        APP_ZIP="${DIST_DIR}/${APP_NAME}-${label}-app.zip"
        rm -f "$APP_ZIP"
        /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
        notarize "$APP_ZIP"
        rm -f "$APP_ZIP"
        APP_ZIP=""
        log "Stapling ${label} app…"
        xcrun stapler staple "$APP_BUNDLE"
        xcrun stapler validate "$APP_BUNDLE"
    fi

    log "Building ${label} DMG…"
    STAGING="$(mktemp -d)"
    cp -R "$APP_BUNDLE" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING" \
        -fs HFS+ -format UDZO -ov "$TEMP_DMG_PATH" >/dev/null
    rm -rf "$STAGING"
    STAGING=""

    log "Signing ${label} DMG…"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$TEMP_DMG_PATH"
    codesign --verify --verbose=2 "$TEMP_DMG_PATH"
    hdiutil verify "$TEMP_DMG_PATH" >/dev/null

    if [ "$NOTARIZED" = 1 ]; then
        log "Notarizing ${label} DMG…"
        notarize "$TEMP_DMG_PATH"
        log "Stapling ${label} DMG…"
        xcrun stapler staple "$TEMP_DMG_PATH"
        xcrun stapler validate "$TEMP_DMG_PATH"
        codesign --verify --verbose=2 "$TEMP_DMG_PATH"
        hdiutil verify "$TEMP_DMG_PATH" >/dev/null
        spctl -a -vv "$APP_BUNDLE"
        spctl -a -t open --context context:primary-signature -vv "$TEMP_DMG_PATH"
    fi

    log "${label} artifact validated; waiting for remaining variants…"
done

# Publish only after every requested architecture passes. This keeps the prior
# complete release intact if any build, signature, or notarization step fails.
for index in "${!TEMP_DMGS[@]}"; do
    mv -f "${TEMP_DMGS[$index]}" "${FINAL_DMGS[$index]}"
done

CHECKSUMS_TMP="${DIST_DIR}/.SHA256SUMS.txt"
shasum -a 256 "${FINAL_DMGS[@]}" | sed 's#  dist/#  #' > "$CHECKSUMS_TMP"
mv -f "$CHECKSUMS_TMP" "${DIST_DIR}/SHA256SUMS.txt"
CHECKSUMS_TMP=""

log "Release complete"
for path in "${FINAL_DMGS[@]}"; do
    if [ "$NOTARIZED" = 1 ]; then
        printf '\033[32m✅ Notarized, stapled DMG: %s\033[0m\n' "$path"
    else
        printf '\033[33m⚠️  Signed local-test DMG: %s\033[0m\n' "$path"
    fi
done
echo "   Checksums: ${DIST_DIR}/SHA256SUMS.txt"
echo "   Users should choose Intel or Apple Silicon for the smallest download,"
echo "   or Universal when the destination Mac architecture is unknown."
