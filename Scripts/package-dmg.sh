#!/usr/bin/env bash
# Build, assemble, ad-hoc sign, and package Alethia as a macOS DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/release}"
PLIST="$ROOT/Apps/Alethia/Resources/Info.plist"
ICON="$ROOT/Apps/Alethia/Resources/AppIcon.icns"
ENTITLEMENTS="$ROOT/Apps/Alethia/Resources/Alethia.entitlements"
BUNDLE_ID="app.alethia.macos"
CONFIGURATION="release"
BUILD_ARCH="${ALETHIA_BUILD_ARCH:-}"
BUNDLE_SIDECAR="${ALETHIA_BUNDLE_SIDECAR:-1}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package-dmg.sh must run on macOS." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"

cd "$ROOT"
BUILD_ARGS=(-c "$CONFIGURATION")
if [[ -n "$BUILD_ARCH" ]]; then
  BUILD_ARGS+=(--arch "$BUILD_ARCH")
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Alethia"

if [[ ! -x "$BIN" ]]; then
  echo "Missing release executable: $BIN" >&2
  exit 1
fi

if [[ ! -f "$ICON" ]]; then
  "$ROOT/Scripts/build-app-icon.sh"
fi

ARCHS="$(lipo -archs "$BIN")"
if [[ "$ARCHS" == *" "* ]]; then
  ARCH="universal"
else
  ARCH="$ARCHS"
fi

WORK_DIR="$ROOT/.build/dmg-package"
APP="$WORK_DIR/Alethia.app"
CONTENTS="$APP/Contents"
DMG_ROOT="$WORK_DIR/dmg-root"
DMG_NAME="Alethia-${VERSION}-${ARCH}.dmg"
DMG="$OUTPUT_DIR/$DMG_NAME"

rm -rf "$WORK_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$DMG_ROOT" "$OUTPUT_DIR"

cp "$BIN" "$CONTENTS/MacOS/Alethia"
cp "$PLIST" "$CONTENTS/Info.plist"
cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"
cp "$ROOT"/Apps/Alethia/Resources/*.svg "$CONTENTS/Resources/"
chmod +x "$CONTENTS/MacOS/Alethia"

if [[ "$BUNDLE_SIDECAR" == "1" || "$BUNDLE_SIDECAR" == "true" ]]; then
  SIDECAR="$CONTENTS/Resources/Sidecar"
  "$ROOT/Scripts/build-sidecar-runtime.sh" "$WORK_DIR/sidecar-runtime"
  mkdir -p "$SIDECAR"
  mv "$WORK_DIR/sidecar-runtime/python" "$SIDECAR/python"
  cp "$ROOT/Tools/crisperwhisper_sidecar/server.py" "$SIDECAR/server.py"
  cp "$ROOT/Scripts/start-bundled-sidecar.sh" "$SIDECAR/start-sidecar.sh"
  chmod +x "$SIDECAR/start-sidecar.sh" "$SIDECAR/python/bin/python3"
fi

# Ad-hoc signing keeps the bundle internally consistent. A future release can
# provide ALETHIA_CODESIGN_IDENTITY when a Developer ID certificate is available.
SIGNING_IDENTITY="${ALETHIA_CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
if ! grep -q '<key>com.apple.security.device.audio-input</key>' <<<"$SIGNED_ENTITLEMENTS"; then
  echo "Packaged app is missing the required audio-input entitlement." >&2
  exit 1
fi

cp -R "$APP" "$DMG_ROOT/Alethia.app"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$DMG" "$DMG.sha256"
hdiutil create \
  -volname "Alethia $VERSION" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG"
hdiutil verify "$DMG"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

printf 'Created %s\n' "$DMG"
printf 'Created %s\n' "$DMG.sha256"
