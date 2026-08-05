#!/usr/bin/env bash
# End-to-end smoke: CrisperWhisper sidecar health + fixture transcription.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="${HOME}/Library/Application Support/Alethia"
WAV="${ROOT}/Fixtures/speech_short.wav"
URL="${ALETHIA_CRISPER_URL:-http://127.0.0.1:8765}"

echo "== Alethia ASR smoke (CrisperWhisper) =="
echo "ROOT=$ROOT"
echo "URL=$URL"

fail=0
check() {
  local label="$1"; shift
  if "$@"; then echo "PASS  $label"; else echo "FAIL  $label"; fail=1; fi
}

check "fixture wav present" test -f "$WAV"
check "sidecar venv present" test -x "$ROOT/Tools/crisperwhisper_sidecar/.venv/bin/python"
check "stable app installed" test -x "${HOME}/Applications/Alethia.app/Contents/MacOS/Alethia" || true

if ! curl -sf "$URL/health" >/dev/null 2>&1; then
  echo "Starting stub sidecar for smoke…"
  export ALETHIA_CRISPER_STUB="${ALETHIA_CRISPER_STUB:-1}"
  nohup "$ROOT/Scripts/start-crisper-sidecar.sh" >"/tmp/alethia-crisper-sidecar-smoke.log" 2>&1 &
  mkdir -p "$SUPPORT" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if curl -sf "$URL/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
fi

check "sidecar /health" curl -sf "$URL/health" >/dev/null

echo "--- transcribe fixture ---"
RESP="$(curl -sf -X POST "$URL/transcribe?mode=intended&language=en" \
  -F "audio=@${WAV};type=audio/wav")"
echo "$RESP"
if echo "$RESP" | grep -q '"text"'; then
  echo "PASS  transcript JSON"
else
  echo "FAIL  transcript JSON"
  fail=1
fi

if [[ $fail -ne 0 ]]; then
  echo "SMOKE FAILED"
  exit 1
fi
echo "SMOKE OK"
