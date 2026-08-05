#!/usr/bin/env bash
# Install a LaunchAgent so the CrisperWhisper sidecar stays up across logins.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="app.alethia.crisperwhisper"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Application Support/Alethia"
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

# Ensure full (non-stub) venv exists.
if [[ ! -x "$ROOT/Tools/crisperwhisper_sidecar/.venv/bin/python" ]] \
  || ! "$ROOT/Tools/crisperwhisper_sidecar/.venv/bin/python" -c "import crisperwhisper" 2>/dev/null; then
  "$ROOT/Scripts/setup-crisperwhisper.sh"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${ROOT}/Scripts/start-crisper-sidecar.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${ROOT}</string>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/crisper-sidecar.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/crisper-sidecar.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>ALETHIA_CRISPER_MODEL</key>
    <string>small</string>
    <key>ALETHIA_CRISPER_BACKEND</key>
    <string>transformers</string>
    <key>ALETHIA_CRISPER_DEVICE</key>
    <string>auto</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl start "$LABEL" || true

echo "Installed LaunchAgent: $PLIST"
echo "Waiting for health…"
for _ in $(seq 1 90); do
  if health="$(curl -sf http://127.0.0.1:8765/health 2>/dev/null)"; then
    if echo "$health" | grep -q '"stub":false\|"stub": false'; then
      echo "Ready: $health"
      exit 0
    fi
  fi
  sleep 1
done
echo "Timed out waiting for sidecar. Check: $LOG_DIR/crisper-sidecar.log" >&2
exit 1
