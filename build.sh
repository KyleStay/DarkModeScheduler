#!/usr/bin/env bash
#
# Builds Dark Mode Scheduler into a signed .app bundle using only swiftc and
# codesign — no Xcode project, no third-party tooling.
#
# Idempotent: safe to re-run. Fails loudly on any error.
#
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DarkModeScheduler"
DISPLAY_NAME="Dark Mode Scheduler"
BUNDLE_ID="com.kyle.darkmodescheduler"
VERSION="1.0"
BUILD_NUMBER="1"
MIN_MACOS="13.0"

BUILD_DIR=".build"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

SOURCES=(main.swift SunCalculator.swift)

echo "==> Cleaning previous bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

# --- Compile. Build a universal binary when possible; always require the host
#     arch. Treat warnings as errors so the build is warnings-clean by contract.
compile_arch() {
    local arch="$1"
    local out="$2"
    /usr/bin/swiftc -O \
        -warnings-as-errors \
        -target "${arch}-apple-macos${MIN_MACOS}" \
        -o "$out" \
        "${SOURCES[@]}"
}

HOST_ARCH="$(uname -m)"
SLICES=()

echo "==> Compiling host slice (${HOST_ARCH})…"
compile_arch "$HOST_ARCH" "${BUILD_DIR}/${APP_NAME}-${HOST_ARCH}"
SLICES+=("${BUILD_DIR}/${APP_NAME}-${HOST_ARCH}")

# Attempt the other arch for a universal binary; non-fatal if it can't build.
OTHER_ARCH="arm64"
[ "$HOST_ARCH" = "arm64" ] && OTHER_ARCH="x86_64"
echo "==> Attempting ${OTHER_ARCH} slice for universal binary…"
if compile_arch "$OTHER_ARCH" "${BUILD_DIR}/${APP_NAME}-${OTHER_ARCH}" 2>/dev/null; then
    SLICES+=("${BUILD_DIR}/${APP_NAME}-${OTHER_ARCH}")
    echo "    ✓ ${OTHER_ARCH} slice built"
else
    echo "    (skipped ${OTHER_ARCH}; building single-arch ${HOST_ARCH})"
fi

echo "==> Assembling binary…"
if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "${MACOS_DIR}/${APP_NAME}"
    echo "    universal: $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"
else
    cp "${SLICES[0]}" "${MACOS_DIR}/${APP_NAME}"
    echo "    single-arch: ${HOST_ARCH}"
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
    <string>Dark Mode Scheduler controls System Events to switch the system appearance between Light and Dark on schedule.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Dark Mode Scheduler</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Also stamp a PkgInfo for completeness.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE"

echo "==> Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo
echo "✅ Build complete."
echo "   App bundle: $(pwd)/${APP_BUNDLE}"
echo "   Launch with: open \"${APP_BUNDLE}\""
echo "   Self-test:   \"${MACOS_DIR}/${APP_NAME}\" --selftest"
