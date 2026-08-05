#!/usr/bin/env bash
# Download / note local inference weights for Alethia (run on your Mac).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS="$ROOT/Models"
mkdir -p "$MODELS"

echo "Alethia model download"
echo "Weights are gitignored. Place files under: $MODELS"
echo
echo "CrisperWhisper models are downloaded automatically by the sidecar"
echo "into the Hugging Face cache on first transcription (default size: turbo)."
echo "Setup the sidecar with: ./Scripts/setup-crisperwhisper.sh"
echo

# Placeholder note for ECAPA weights (optional until native GGML runner lands)
if [[ ! -f "$MODELS/ggml-speaker-ecapa-tdnn.bin" ]]; then
  echo "note: place ECAPA GGML weights at Models/ggml-speaker-ecapa-tdnn.bin when available"
  echo "      Alethia falls back to on-device spectral fingerprints until then."
fi

cat > "$MODELS/README.md" <<'EOF'
# Models

Downloaded weights live here and are gitignored.

Expected files (v1):

- CrisperWhisper — managed by the Python sidecar (HF cache); default size `turbo`
- `ggml-silero-*.bin` — Silero VAD (optional; energy VAD stub works)
- `ggml-speaker-ecapa-tdnn.bin` — speaker embeddings (optional; spectral fallback)

Run `Scripts/setup-crisperwhisper.sh` on macOS, then `Scripts/start-crisper-sidecar.sh`.
EOF

echo
echo "Done."
