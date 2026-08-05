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

# ECAPA-TDNN: SpeechBrain weights via the Crisper sidecar (preferred).
echo "ECAPA speaker embeddings: SpeechBrain spkrec-ecapa-voxceleb"
echo "  Cached at ~/.cache/alethia/ecapa-voxceleb on first sidecar start."
echo "  Disable with ALETHIA_ECAPA=0 (spectral fingerprints only)."
if [[ ! -f "$MODELS/ggml-speaker-ecapa-tdnn.bin" ]]; then
  echo "note: optional native GGML ECAPA at Models/ggml-speaker-ecapa-tdnn.bin is unused until a runner lands."
fi

cat > "$MODELS/README.md" <<'EOF'
# Models

Downloaded weights live here and are gitignored.

Expected files (v1):

- CrisperWhisper — managed by the Python sidecar (HF cache); default size `turbo`
- ECAPA-TDNN — SpeechBrain via sidecar `POST /embed` (`~/.cache/alethia/ecapa-voxceleb`)
- `ggml-silero-*.bin` — Silero VAD (optional; energy VAD stub works)
- `ggml-speaker-ecapa-tdnn.bin` — optional native path (not required; sidecar ECAPA is used)

Run `Scripts/setup-crisperwhisper.sh` on macOS, then `Scripts/start-crisper-sidecar.sh`.
EOF

echo
echo "Done."
