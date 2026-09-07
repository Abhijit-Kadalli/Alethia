#!/usr/bin/env bash
# Build App/AppIcon.icns from App/alethia-logo.svg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/App/alethia-logo.svg"
OUT="$ROOT/App/AppIcon.icns"
WORKDIR="$(mktemp -d)"
ICONSET="$WORKDIR/AppIcon.iconset"
MASTER="$WORKDIR/master.png"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ ! -f "$SVG" ]]; then
  echo "Missing logo SVG: $SVG" >&2
  exit 1
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert required (brew install librsvg)" >&2
  exit 1
fi

mkdir -p "$ICONSET"
rsvg-convert -w 1024 -h 1024 "$SVG" -o "$MASTER"

# iconutil expects these exact names.
declare -a SIZES=(16 32 128 256 512)
for s in "${SIZES[@]}"; do
  sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
sips -z 32 32 "$MASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 64 64 "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 256 256 "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 1024 1024 "$MASTER" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Wrote $OUT ($(wc -c <"$OUT") bytes)"
