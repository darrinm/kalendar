#!/bin/bash
# Build release and assemble Kalendar.app (adapted from Kapture's scripts/bundle.sh).
#
# Local runs sign with an Apple Development identity, which keeps Keychain access stable across
# rebuilds. CI imports a Developer ID identity and sets KALENDAR_VERSION, KALENDAR_BUILD and
# KALENDAR_PUBLIC_ED_KEY; only then does the app get a working updater and a signature macOS
# accepts on another Mac.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
unset SDKROOT MACOSX_DEPLOYMENT_TARGET

VERSION="${KALENDAR_VERSION:-0.1.0}"
BUILD="${KALENDAR_BUILD:-1}"
PUBLIC_ED_KEY="${KALENDAR_PUBLIC_ED_KEY:-}"
FEED_URL="${KALENDAR_FEED_URL:-https://github.com/darrinm/kalendar/releases/latest/download/appcast.xml}"

# -warnings-as-errors: project warnings fail the build (dependencies are unaffected).
# The rpath lets the executable find Sparkle.framework inside the bundle.
# Output is captured first so a failed build is never hidden by the grep filter, and a stale
# .build/release/Kalendar from an earlier run is never bundled.
build_out=$(/usr/bin/xcrun swift build -c release -Xswiftc -warnings-as-errors \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks 2>&1) || {
  printf '%s\n' "$build_out"
  echo "build failed"
  exit 1
}
printf '%s\n' "$build_out" | grep -vE "unhandled Platform key" || true
BIN=.build/release/Kalendar

APP=dist/Kalendar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Kalendar"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sparkle's MIT license must ship with the binary
cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

# Sparkle ships as an XCFramework; the .app carries the macOS slice, with its XPC services and
# Updater.app nested inside the framework where Sparkle expects them.
SPARKLE=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1)
# The executable links Sparkle, so a bundle without it cannot launch. Fail here rather than let
# the release workflow sign, notarize and publish it.
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found under .build/artifacts" >&2; exit 1; }
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.massena.kalendar</string>
  <key>CFBundleName</key><string>Kalendar</string>
  <key>CFBundleDisplayName</key><string>Kalendar</string>
  <key>CFBundleExecutable</key><string>Kalendar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Darrin Massena</string>
  <key>SUFeedURL</key><string>${FEED_URL}</string>
  <key>SUPublicEDKey</key><string>${PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict></plist>
PLIST

# Prefer a real signing identity: a stable identity keeps Keychain item access across rebuilds.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')
SIGN_ID="${SIGN_ID:--}"

# Notarization requires the hardened runtime and a secure timestamp. A local Apple Development
# build skips both: --timestamp needs the network and the runtime blocks the debugger.
# Kalendar needs no entitlements (§8.5), so nothing is passed with --entitlements.
EXTRA=()
case "$SIGN_ID" in
  "Developer ID Application"*) EXTRA=(--options runtime --timestamp) ;;
esac

# inside out: nested code first, then the app, so the outer signature seals what is already sealed
while IFS= read -r nested; do
  codesign --force "${EXTRA[@]}" -s "$SIGN_ID" "$nested"
done < <(find "$APP/Contents/Frameworks/Sparkle.framework" \
  \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) -maxdepth 4)
codesign --force "${EXTRA[@]}" -s "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${EXTRA[@]}" -s "$SIGN_ID" "$APP"
# recorded so the DMG step signs the image with the same certificate as the app
printf '%s' "$SIGN_ID" > dist/.sign-identity
echo "signed as: $SIGN_ID"
[ -n "$PUBLIC_ED_KEY" ] || echo "note: no SUPublicEDKey — in-app updates are disabled in this build"
echo "built $APP ($VERSION build $BUILD) — run with: open $APP"
