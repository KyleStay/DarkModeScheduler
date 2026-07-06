#!/usr/bin/env bash
#
# Production release pipeline for Dark Mode Scheduler.
#
# Produces a Developer ID-signed, Hardened-Runtime, notarized + stapled app
# packaged in a drag-to-Applications DMG — the friendliest install for a
# menu-bar app distributed outside the Mac App Store. Gatekeeper opens it with
# no scary warnings.
#
# Stages:
#   1. Resolve the Developer ID signing identity + Team ID.
#   2. Build + sign the universal app (Hardened Runtime + entitlements) via build.sh.
#   3. Verify the signature.
#   4. Notarize the APP and staple it (so it passes even offline).
#   5. Assemble a signed DMG from the stapled app.
#   6. Notarize the DMG and staple it.
#   7. Final Gatekeeper assessment.
#
# Notarization needs your Apple credentials ONCE. Set them up with:
#     xcrun notarytool store-credentials "DarkModeScheduler" \
#         --apple-id "you@example.com" --team-id "TF2BG2VDPD" \
#         --password "app-specific-password"     # appleid.apple.com → App-Specific Passwords
# then run:  NOTARY_PROFILE=DarkModeScheduler ./release.sh
#
# Config (all env-overridable):
#   SIGN_IDENTITY   signing identity (default: first "Developer ID Application")
#   TEAM_ID         Apple Team ID (default: derived from the identity)
#   NOTARY_PROFILE  notarytool keychain profile name  (preferred)
#   APPLE_ID + NOTARY_PASSWORD  alternative to NOTARY_PROFILE (app-specific pwd)
#   SKIP_NOTARIZE   non-empty → build + sign + DMG only (local test build)
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DarkModeScheduler"
DISPLAY_NAME="Dark Mode Scheduler"
APP_BUNDLE="${APP_NAME}.app"
ENTITLEMENTS="${APP_NAME}.entitlements"
DIST_DIR="dist"
DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠️  %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

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

have_credentials() {
    [ -n "$NOTARY_PROFILE" ] || { [ -n "$APPLE_ID" ] && [ -n "$NOTARY_PASSWORD" ]; }
}

# --- 1. Resolve signing identity + Team ID ----------------------------------
[ -f "$ENTITLEMENTS" ] || die "Missing $ENTITLEMENTS"
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

# --- 2. Build + sign (Developer ID + Hardened Runtime) ----------------------
log "Building universal app, signed with Developer ID + Hardened Runtime…"
CODESIGN_IDENTITY="$SIGN_IDENTITY" \
CODESIGN_ENTITLEMENTS="$ENTITLEMENTS" \
CODESIGN_RUNTIME=1 \
    ./build.sh

# --- 3. Verify the signature ------------------------------------------------
log "Verifying code signature…"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -Ei "Authority|TeamIdentifier|Runtime|flags=" || true

rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"

# --- 4. Notarize + staple the APP (works offline once stapled) --------------
NOTARIZED=0
if [ -n "$SKIP_NOTARIZE" ]; then
    warn "SKIP_NOTARIZE set — building a signed but UN-notarized DMG (local test only)."
elif have_credentials; then
    log "Notarizing the app (this can take a few minutes)…"
    APP_ZIP="${DIST_DIR}/${APP_NAME}-app.zip"
    /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
    notarize "$APP_ZIP"
    rm -f "$APP_ZIP"
    log "Stapling the app…"
    xcrun stapler staple "$APP_BUNDLE"
    xcrun stapler validate "$APP_BUNDLE"
    NOTARIZED=1
else
    warn "No notarization credentials — building a signed but UN-notarized DMG."
    echo "    Set up once, then re-run to notarize:"
    echo "      xcrun notarytool store-credentials \"$APP_NAME\" \\"
    echo "        --apple-id \"you@example.com\" --team-id \"$TEAM_ID\" --password \"app-specific-pwd\""
    echo "      NOTARY_PROFILE=$APP_NAME ./release.sh"
fi

# --- 5. Assemble the drag-to-Applications DMG (from the stapled app) --------
log "Building DMG…"
STAGING="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"      # drag target
rm -f "$DMG_PATH"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO -ov "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

log "Signing DMG…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

# --- 6. Notarize + staple the DMG -------------------------------------------
if [ "$NOTARIZED" = 1 ]; then
    log "Notarizing the DMG…"
    notarize "$DMG_PATH"
    log "Stapling the DMG…"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

# --- 7. Final assessment ----------------------------------------------------
log "Result"
if [ "$NOTARIZED" = 1 ]; then
    echo "   Gatekeeper (app): $(spctl -a -vv "$APP_BUNDLE" 2>&1 | tr '\n' ' ')"
    spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" 2>&1 | sed 's/^/   DMG: /' || true
    printf '\033[32m✅ Notarized, stapled DMG ready: %s\033[0m\n' "$DMG_PATH"
    echo "   Ship this DMG. Users double-click it, drag the app to Applications, done."
else
    printf '\033[33m⚠️  Signed (NOT notarized) DMG: %s\033[0m\n' "$DMG_PATH"
    echo "   Fine for local testing. Users would hit a Gatekeeper warning until notarized."
fi
