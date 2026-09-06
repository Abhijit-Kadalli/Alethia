#!/usr/bin/env bash
# Package Alethia.app into a compressed DMG with an /Applications shortcut.
#
#   Scripts/package-dmg.sh [output-dir]      (default: release)
#
# Environment: see package-app.sh, plus
#   ALETHIA_NOTARY_KEY_ID / ALETHIA_NOTARY_ISSUER_ID / ALETHIA_NOTARY_KEY_PATH
#     When all three are set and a Developer ID identity is used, the DMG is notarized
#     with `xcrun notarytool` and stapled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/release}"
PLIST="$ROOT/App/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
WORK="$ROOT/.build/dmg"

rm -rf "$WORK"
mkdir -p "$WORK/root" "$OUT"

APP="$("$ROOT/Scripts/package-app.sh" "$WORK" | tail -n1)"
[[ -d "$APP" ]] || { echo "package-app.sh did not produce an app" >&2; exit 1; }

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Alethia" | tr ' ' '-')"
DMG_NAME="Alethia-${VERSION}-${ARCHS}.dmg"
DMG="$OUT/$DMG_NAME"

cp -R "$APP" "$WORK/root/Alethia.app"
ln -s /Applications "$WORK/root/Applications"

rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "Alethia $VERSION" -srcfolder "$WORK/root" -ov -format UDZO -quiet "$DMG"
hdiutil verify -quiet "$DMG"

if [[ -n "${ALETHIA_CODESIGN_IDENTITY:-}" && "${ALETHIA_CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --sign "$ALETHIA_CODESIGN_IDENTITY" "$DMG"
  if [[ -n "${ALETHIA_NOTARY_KEY_ID:-}" && -n "${ALETHIA_NOTARY_ISSUER_ID:-}" && -n "${ALETHIA_NOTARY_KEY_PATH:-}" ]]; then
    echo "▸ notarizing"
    xcrun notarytool submit "$DMG" --key "$ALETHIA_NOTARY_KEY_PATH" \
      --key-id "$ALETHIA_NOTARY_KEY_ID" --issuer "$ALETHIA_NOTARY_ISSUER_ID" --wait
    xcrun stapler staple "$DMG"
  fi
fi

(cd "$OUT" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
ls -la "$DMG" "$DMG.sha256"
