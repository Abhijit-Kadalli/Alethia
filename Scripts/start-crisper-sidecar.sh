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
export ALETHIA_CRISPER_MODEL="${ALETHIA_CRISPER_MODEL:-turbo}"
export ALETHIA_CRISPER_BACKEND="${ALETHIA_CRISPER_BACKEND:-transformers}"
# Never inherit a leftover stub flag from the parent shell.
unset ALETHIA_CRISPER_STUB

exec "$PY" "$SIDECAR/server.py"
