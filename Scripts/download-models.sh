#!/usr/bin/env bash
# Download local inference weights for Alethia (run on your Mac).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$ROOT/Models"
mkdir -p "$MODELS"

echo "Alethia model download"
echo "Weights are gitignored. Place files under: $MODELS"
echo

download() {
  local url="$1"
  local out="$2"
  if [[ -f "$out" ]]; then
    echo "exists: $out"
    return
  fi
  echo "fetch: $out"
  curl -L --fail --progress-bar -o "$out" "$url"
}

# Whisper.cpp ggml (large-v3-turbo quantized) — Hugging Face ggml-org mirror
WHISPER_URL="${WHISPER_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin}"
download "$WHISPER_URL" "$MODELS/ggml-large-v3-turbo-q5_0.bin"

# Silero VAD (ggml) — optional; EnergyVADStub works until this is wired
# Uncomment when the exact artifact URL is pinned in docs:
# download "$SILERO_URL" "$MODELS/ggml-silero-v6.2.0.bin"

cat > "$MODELS/README.md" <<'EOF'
# Models

Downloaded weights live here and are gitignored.

Expected files (v1):

- `ggml-large-v3-turbo-q5_0.bin` — whisper.cpp ASR
- `ggml-silero-*.bin` — Silero VAD (optional until CoreML path lands)
- `ggml-speaker-ecapa-tdnn.bin` — speaker embeddings (optional until wired)

Re-run `Scripts/download-models.sh` after cloning.
EOF

echo
echo "Done. ASR model ready for whisper.cpp integration."
