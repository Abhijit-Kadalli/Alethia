#!/usr/bin/env bash
# Start the CrisperWhisper HTTP sidecar (foreground).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR="$ROOT/Tools/crisperwhisper_sidecar"
VENV="$SIDECAR/.venv"
PY="$VENV/bin/python"

if [[ ! -x "$PY" ]]; then
  echo "Sidecar venv missing. Run: ./Scripts/setup-crisperwhisper.sh" >&2
  exit 1
fi

export ALETHIA_CRISPER_HOST="${ALETHIA_CRISPER_HOST:-127.0.0.1}"
export ALETHIA_CRISPER_PORT="${ALETHIA_CRISPER_PORT:-8765}"
# small is snappy for dictation on Mac; set ALETHIA_CRISPER_MODEL=turbo for higher quality.
export ALETHIA_CRISPER_MODEL="${ALETHIA_CRISPER_MODEL:-small}"
export ALETHIA_CRISPER_BACKEND="${ALETHIA_CRISPER_BACKEND:-transformers}"
export ALETHIA_CRISPER_DEVICE="${ALETHIA_CRISPER_DEVICE:-auto}"
# ALETHIA_CRISPER_STUB is intentionally preserved for CI. Real app launchers
# explicitly unset it before starting this script.
exec "$PY" "$SIDECAR/server.py"
