#!/usr/bin/env bash
# Build Alethia in release and assemble a signed Alethia.app.
#
#   Scripts/package-app.sh [output-dir]      (default: .build/package)
#
# Environment:
#   ALETHIA_BUILD_ARCH        arm64 | x86_64 | universal   (default: host arch)
#   ALETHIA_CODESIGN_IDENTITY Developer ID identity        (default: "-" ad-hoc)
#   ALETHIA_MAX_APP_BYTES     size budget for the .app     (default: 10 MiB; 0 disables)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/package}"
PLIST="$ROOT/App/Info.plist"
ICON="$ROOT/App/AppIcon.icns"
ENTITLEMENTS="$ROOT/App/Alethia.entitlements"
BUNDLE_ID="app.alethia.macos"
ARCH="${ALETHIA_BUILD_ARCH:-$(uname -m)}"
MAX_BYTES="${ALETHIA_MAX_APP_BYTES:-10485760}"
IDENTITY="${ALETHIA_CODESIGN_IDENTITY:--}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "package-app.sh must run on macOS." >&2
  exit 1
fi

cd "$ROOT"
BUILD_ARGS=(-c release)
case "$ARCH" in
  universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
  arm64|x86_64) BUILD_ARGS+=(--arch "$ARCH") ;;
  *) echo "Unknown ALETHIA_BUILD_ARCH: $ARCH" >&2; exit 1 ;;
esac

echo "▸ swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}" -Xswiftc -Osize
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Alethia"
[[ -x "$BIN" ]] || { echo "Missing executable $BIN" >&2; exit 1; }

APP="$OUT/Alethia.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/Alethia"
strip -x "$CONTENTS/MacOS/Alethia" 2>/dev/null || true
cp "$PLIST" "$CONTENTS/Info.plist"
[[ -f "$ICON" ]] && cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# SwiftPM resource bundles (if any dependency ships resources).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

echo "▸ codesign ($IDENTITY)"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

APP_BYTES="$(du -sk "$APP" | awk '{print $1 * 1024}')"
EXE_BYTES="$(stat -f%z "$CONTENTS/MacOS/Alethia")"
printf '▸ Alethia.app: %.2f MiB total, executable %.2f MiB (arch: %s)\n' \
  "$(echo "$APP_BYTES / 1048576" | bc -l)" "$(echo "$EXE_BYTES / 1048576" | bc -l)" "$(lipo -archs "$BIN")"

if [[ "$MAX_BYTES" != "0" && "$APP_BYTES" -gt "$MAX_BYTES" ]]; then
  echo "✗ Alethia.app is $APP_BYTES bytes, over the $MAX_BYTES byte budget." >&2
  du -sh "$CONTENTS"/* >&2 || true
  exit 2
fi
echo "$APP"
