#!/usr/bin/env bash
# Package the SPM Alethia binary as a minimal .app so MenuBarExtra shows in the menu bar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/Alethia"
APP="$ROOT/.build/Alethia.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN" "$MACOS/Alethia"
cp "$ROOT/Apps/Alethia/Resources/Info.plist" "$CONTENTS/Info.plist"
chmod +x "$MACOS/Alethia"

# Kill any previous instance launched from this bundle or bare binary.
pkill -f '/\.build/(release|debug)/Alethia$' 2>/dev/null || true
pkill -f '/\.build/Alethia\.app/Contents/MacOS/Alethia$' 2>/dev/null || true
sleep 0.3

open "$APP"
echo "Launched: $APP"
echo "Look for the ear / waveform icon in the menu bar (may be in the overflow » chevron)."
