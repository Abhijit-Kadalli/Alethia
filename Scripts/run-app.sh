#!/usr/bin/env bash
# Package + ad-hoc sign Alethia into a *stable* path so Accessibility/TCC can stick.
# Ensures CrisperWhisper sidecar venv exists and records repo root for ASR discovery.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
BUNDLE_ID="app.alethia.macos"
SUPPORT="${HOME}/Library/Application Support/Alethia"
STABLE="${HOME}/Applications/Alethia.app"

# Always use a full (non-stub) sidecar for the real app.
unset ALETHIA_CRISPER_STUB || true
if [[ ! -x "$ROOT/Tools/crisperwhisper_sidecar/.venv/bin/python" ]] \
  || ! "$ROOT/Tools/crisperwhisper_sidecar/.venv/bin/python" -c "import crisperwhisper" 2>/dev/null; then
  echo "Setting up CrisperWhisper sidecar (full install)…"
  "$ROOT/Scripts/setup-crisperwhisper.sh"
fi

# Prefer LaunchAgent keep-alive so ASR doesn't die between sessions.
if [[ -x "$ROOT/Scripts/install-crisper-launchagent.sh" ]]; then
  "$ROOT/Scripts/install-crisper-launchagent.sh" || true
fi

swift build -c "$CONFIG"

# Ensure app icon exists (from alethia-logo.svg).
ICON_SRC="$ROOT/Apps/Alethia/Resources/AppIcon.icns"
if [[ ! -f "$ICON_SRC" ]]; then
  "$ROOT/Scripts/build-app-icon.sh"
fi

BIN="$ROOT/.build/$CONFIG/Alethia"
STAGING="$ROOT/.build/Alethia.app"
CONTENTS="$STAGING/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$STAGING"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN" "$MACOS/Alethia"
cp "$ROOT/Apps/Alethia/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ICON_SRC" "$RESOURCES/AppIcon.icns"
# Keep SVG assets alongside for reference / future UI use.
cp "$ROOT/Apps/Alethia/Resources/"*.svg "$RESOURCES/" 2>/dev/null || true
chmod +x "$MACOS/Alethia"
chmod +x "$ROOT/Scripts/build-app-icon.sh" 2>/dev/null || true

codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$STAGING"

mkdir -p "$(dirname "$STABLE")"
rm -rf "$STABLE"
cp -R "$STAGING" "$STABLE"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$STABLE"
xattr -cr "$STABLE" 2>/dev/null || true

mkdir -p "$SUPPORT"
printf '%s\n' "$ROOT" > "$SUPPORT/repo_root.txt"

# Replace a stub sidecar (or missing one) with the real CrisperWhisper server.
need_sidecar=1
if health="$(curl -sf "http://127.0.0.1:8765/health" 2>/dev/null)"; then
  if echo "$health" | grep -q '"stub": *false\|"stub":false'; then
    need_sidecar=0
    echo "CrisperWhisper sidecar already running (real model)."
  else
    echo "Stopping stub sidecar…"
    pkill -f 'crisperwhisper_sidecar/server.py' 2>/dev/null || true
    sleep 0.5
  fi
fi
if [[ "$need_sidecar" -eq 1 ]]; then
  nohup env -u ALETHIA_CRISPER_STUB "$ROOT/Scripts/start-crisper-sidecar.sh" >"$SUPPORT/crisper-sidecar.log" 2>&1 &
  echo "Started CrisperWhisper sidecar (log: $SUPPORT/crisper-sidecar.log)"
  echo "First launch may download the turbo model — wait until /health shows stub:false."
  for _ in $(seq 1 120); do
    if health="$(curl -sf "http://127.0.0.1:8765/health" 2>/dev/null)"; then
      if echo "$health" | grep -q '"stub": *false\|"stub":false'; then
        echo "Sidecar ready: $health"
        break
      fi
      # Still loading model (process up but stub shouldn't be true for full install)
      if echo "$health" | grep -q '"ok": *true\|"ok":true'; then
        if echo "$health" | grep -q '"stub": *true\|"stub":true'; then
          echo "ERROR: sidecar still in stub mode. Re-run without ALETHIA_CRISPER_STUB." >&2
          exit 1
        fi
      fi
    fi
    sleep 1
  done
fi

pkill -f '/Alethia\.app/Contents/MacOS/Alethia$' 2>/dev/null || true
pkill -f '/\.build/(release|debug)/Alethia$' 2>/dev/null || true
sleep 0.4

open "$STABLE"
echo "Launched: $STABLE"
echo "ASR:      http://127.0.0.1:8765 (CrisperWhisper sidecar)"
echo "Menu bar: waveform / record (or overflow »)."
echo "Dictation: hold Fn"
