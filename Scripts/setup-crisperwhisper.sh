#!/usr/bin/env bash
# Create a local venv and install the CrisperWhisper sidecar for macOS.
# Use ALETHIA_CRISPER_STUB=1 to install flask-only deps (CI / smoke without models).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR="$ROOT/Tools/crisperwhisper_sidecar"
VENV="$SIDECAR/.venv"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "setup-crisperwhisper.sh is intended for macOS (Darwin)."
  exit 1
fi

pick_python() {
  local candidate
  for candidate in \
    "${ALETHIA_PYTHON:-}" \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3.11 \
    /opt/homebrew/bin/python3.10 \
    /usr/local/bin/python3.12 \
    /usr/local/bin/python3.11 \
    /usr/local/bin/python3.10 \
    python3.12 \
    python3.11 \
    python3.10 \
    python3
  do
    [[ -z "$candidate" ]] && continue
    if command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]]; then
      local bin
      bin="$(command -v "$candidate" 2>/dev/null || echo "$candidate")"
      local ver
      ver="$("$bin" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"
      if [[ -n "$ver" ]]; then
        local major minor
        major="${ver%%.*}"
        minor="${ver#*.}"
        if (( major > 3 || (major == 3 && minor >= 10) )); then
          echo "$bin"
          return 0
        fi
      fi
    fi
  done
  return 1
}

if ! PY="$(pick_python)"; then
  cat >&2 <<'EOF'
CrisperWhisper requires Python 3.10+.

Install one of:
  brew install python@3.12
Then re-run: ./Scripts/setup-crisperwhisper.sh
EOF
  exit 1
fi

echo "Using Python: $PY ($("$PY" --version))"

rm -rf "$VENV"
"$PY" -m venv "$VENV"
# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --upgrade pip

if [[ "${ALETHIA_CRISPER_STUB:-}" == "1" || "${ALETHIA_CRISPER_STUB:-}" == "true" ]]; then
  pip install -r "$SIDECAR/requirements-stub.txt"
  MODE_MSG="STUB (flask only)"
else
  pip install -r "$SIDECAR/requirements.txt"
  MODE_MSG="full CrisperWhisper (transformers)"
fi

mkdir -p "${HOME}/Library/Application Support/Alethia"
printf '%s\n' "$ROOT" > "${HOME}/Library/Application Support/Alethia/repo_root.txt"

cat <<EOF
CrisperWhisper sidecar ready ($MODE_MSG).

  python: $PY
  venv:   $VENV
  start:  ./Scripts/start-crisper-sidecar.sh
  stub:   ALETHIA_CRISPER_STUB=1 ./Scripts/start-crisper-sidecar.sh

First real transcription downloads the model (default: turbo) into the HF cache.
First ECAPA load downloads SpeechBrain weights into ~/.cache/alethia/ecapa-voxceleb.
EOF
