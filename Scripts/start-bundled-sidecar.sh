#!/usr/bin/env bash
# Start the sidecar from Alethia.app/Contents/Resources/Sidecar.
set -euo pipefail

SIDECAR="$(cd "$(dirname "$0")" && pwd)"
PYTHON="$SIDECAR/python/bin/python3"
SERVER="$SIDECAR/server.py"
SUPPORT="${HOME}/Library/Application Support/Alethia"
MODELS="$SUPPORT/Models"

if [[ ! -x "$PYTHON" || ! -f "$SERVER" ]]; then
  echo "Alethia's bundled ASR runtime is incomplete." >&2
  exit 1
fi

mkdir -p "$MODELS/huggingface" "$MODELS/ecapa"

export ALETHIA_CRISPER_HOST="${ALETHIA_CRISPER_HOST:-127.0.0.1}"
export ALETHIA_CRISPER_PORT="${ALETHIA_CRISPER_PORT:-8765}"
export ALETHIA_CRISPER_MODEL="${ALETHIA_CRISPER_MODEL:-small}"
export ALETHIA_CRISPER_BACKEND="${ALETHIA_CRISPER_BACKEND:-transformers}"
export ALETHIA_CRISPER_DEVICE="${ALETHIA_CRISPER_DEVICE:-auto}"
export ALETHIA_MODEL_DIR="$MODELS"
export HF_HOME="${HF_HOME:-$MODELS/huggingface}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$HF_HOME/hub}"
export ALETHIA_ECAPA_CACHE="${ALETHIA_ECAPA_CACHE:-$MODELS/ecapa}"
export PYTHONNOUSERSITE=1
export PYTHONUNBUFFERED=1
unset ALETHIA_CRISPER_STUB

exec "$PYTHON" "$SERVER"
