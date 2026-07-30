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

# Tiny model — used by Darwin CI smoke tests (fast)
download \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" \
  "$MODELS/ggml-tiny.bin"

# Whisper.cpp ggml (large-v3-turbo quantized) for higher quality local ASR
WHISPER_URL="${WHISPER_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin}"
download "$WHISPER_URL" "$MODELS/ggml-large-v3-turbo-q5_0.bin"

# Placeholder note for ECAPA weights (optional until native GGML runner lands)
if [[ ! -f "$MODELS/ggml-speaker-ecapa-tdnn.bin" ]]; then
  echo "note: place ECAPA GGML weights at Models/ggml-speaker-ecapa-tdnn.bin when available"
  echo "      Alethia falls back to on-device spectral fingerprints until then."
fi

cat > "$MODELS/README.md" <<'EOF'
# Models

Downloaded weights live here and are gitignored.

Expected files (v1):

- `ggml-tiny.bin` — fast ASR for CI / smoke
- `ggml-large-v3-turbo-q5_0.bin` — higher-quality whisper.cpp ASR
- `ggml-silero-*.bin` — Silero VAD (optional; energy VAD stub works)
- `ggml-speaker-ecapa-tdnn.bin` — speaker embeddings (optional; spectral fallback)

Also run `Scripts/setup-whisper-darwin.sh` on macOS to build the Metal whisper-cli.
EOF

echo
echo "Done."
