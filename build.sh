#!/usr/bin/env bash
#
# Builds Dark Mode Scheduler into a signed .app bundle using only swiftc and
# codesign — no Xcode project, no third-party tooling.
#
# Idempotent: safe to re-run. Fails loudly on any error.
#
# Config:
#   BUILD_ARCH  target architecture: universal (default), arm64, or x86_64
#   DISTRIBUTION_CHANNEL  full (default) or app-store
#   APP_OUTPUT_DIR  optional product directory override
#   CODESIGN_IDENTITY  optional Developer ID override; ad-hoc signing is rejected
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DarkModeScheduler"
DISPLAY_NAME="Dark Mode Scheduler"
BUNDLE_ID="com.kyle.darkmodescheduler"
VERSION="2.8"
BUILD_NUMBER="10"
MIN_MACOS="13.0"
BUILD_ARCH="${BUILD_ARCH:-universal}"
DISTRIBUTION_CHANNEL="${DISTRIBUTION_CHANNEL:-full}"

case "$DISTRIBUTION_CHANNEL" in
    full)
        BUILD_DIR="${BUILD_INTERMEDIATES_DIR:-.build/full-intermediates}"
        APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-.}"
        SWIFT_CHANNEL_FLAGS=(-D FULL)
        DEFAULT_ENTITLEMENTS="DarkModeScheduler.entitlements"
        ;;
    app-store)
        BUILD_DIR="${BUILD_INTERMEDIATES_DIR:-.build/app-store-intermediates}"
        APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-.build/app-store-product}"
        SWIFT_CHANNEL_FLAGS=(-D APP_STORE)
        DEFAULT_ENTITLEMENTS="DarkModeScheduler-AppStore.entitlements"
        ;;
    *)
        echo "✗ Unsupported DISTRIBUTION_CHANNEL '$DISTRIBUTION_CHANNEL' (expected full or app-store)." >&2
        exit 1
        ;;
esac

SIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Kyle Stay (TF2BG2VDPD)}"
CODESIGN_ENTITLEMENTS="${CODESIGN_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}"
CODESIGN_RUNTIME="${CODESIGN_RUNTIME:-1}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "✗ Ad-hoc signing is prohibited. Use the configured Developer ID identity." >&2
    exit 1
fi

APP_BUNDLE="${APP_OUTPUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

SOURCES=(
    main.swift
    AppModel.swift
    PopoverView.swift
    PresentationHost.swift
    MenuBarDiagnostics.swift
    Services.swift
    Support.swift
    Scheduler.swift
    SunCalculator.swift
    DistributionChannel.swift
    BackgroundVerification.swift
)

case "$BUILD_ARCH" in
    universal) TARGET_ARCHS=(x86_64 arm64) ;;
    x86_64|arm64) TARGET_ARCHS=("$BUILD_ARCH") ;;
    *)
        echo "✗ Unsupported BUILD_ARCH '$BUILD_ARCH' (expected universal, x86_64, or arm64)." >&2
        exit 1
        ;;
esac

echo "==> Cleaning previous bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR" "$APP_OUTPUT_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

# --- Compile. The requested architecture is explicit so release builds cannot
#     silently fall back from universal to a single architecture. Treat warnings
#     as errors so the build is warnings-clean by contract.
compile_arch() {
    local arch="$1"
    local out="$2"
    /usr/bin/swiftc -O \
        -warnings-as-errors \
        -module-cache-path "${BUILD_DIR}/module-cache" \
        -target "${arch}-apple-macos${MIN_MACOS}" \
        "${SWIFT_CHANNEL_FLAGS[@]}" \
        -o "$out" \
        "${SOURCES[@]}"
}

SLICES=()
for arch in "${TARGET_ARCHS[@]}"; do
    echo "==> Compiling ${arch} slice…"
    slice="${BUILD_DIR}/${APP_NAME}-${arch}"
    compile_arch "$arch" "$slice"
    SLICES+=("$slice")
done

echo "==> Assembling binary…"
if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${APP_NAME}"
    echo "    universal: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"
else
    cp "${SLICES[0]}" "${MACOS_DIR}/${APP_NAME}"
    echo "    single-arch: ${TARGET_ARCHS[0]}"
fi
chmod +x "${MACOS_DIR}/${APP_NAME}"

echo "==> Writing Info.plist…"
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Dark Mode Scheduler controls System Events only when you choose to switch the system appearance between Light and Dark on schedule.</string>
    <key>NSLocationUsageDescription</key>
    <string>Dark Mode Scheduler can use your location to compute local sunrise and sunset times. This is optional — a postal code works without it.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Dark Mode Scheduler can use your location to compute local sunrise and sunset times. This is optional — a postal code works without it.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Dark Mode Scheduler</string>
    <key>ITSAppUsesNonExemptEncryption</key>
    <false/>
    <key>DarkModeSchedulerDistributionChannel</key>
    <string>${DISTRIBUTION_CHANNEL}</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Also stamp a PkgInfo for completeness.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# --- Code signing. Every app build is Developer ID signed. Local builds may be
#     unnotarized, but ad-hoc and unsigned app bundles are prohibited.
#       CODESIGN_IDENTITY    signing identity (default: Kyle's Developer ID)
#       CODESIGN_ENTITLEMENTS  path to an entitlements plist (optional)
#       CODESIGN_RUNTIME     non-empty → enable the Hardened Runtime (default on)
CODESIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [ -n "${CODESIGN_RUNTIME:-}" ]; then
    CODESIGN_ARGS+=(--options runtime)
fi
if [ -n "${CODESIGN_ENTITLEMENTS:-}" ]; then
    CODESIGN_ARGS+=(--entitlements "$CODESIGN_ENTITLEMENTS")
fi
echo "==> Code signing as: ${SIGN_IDENTITY}…"
CODESIGN_ARGS+=(--timestamp)
# No --deep: the app has no nested code (single binary), so signing the bundle
# directly is correct and avoids --deep's deprecated behavior.
codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"

echo "==> Verifying signature…"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo
echo "✅ Build complete."
echo "   Channel:    ${DISTRIBUTION_CHANNEL}"
echo "   App bundle: $(pwd)/${APP_BUNDLE}"
echo "   Launch with: open \"${APP_BUNDLE}\""
echo "   Self-test:   \"${MACOS_DIR}/${APP_NAME}\" --selftest"
