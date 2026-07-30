#!/usr/bin/env bash
# Build whisper.cpp and fetch a tiny GGML model for Darwin CI / local smoke tests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
WHISPER_DIR="$TOOLS/whisper.cpp"
MODELS="$ROOT/Models"
mkdir -p "$TOOLS" "$MODELS"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "setup-whisper-darwin.sh is intended for macOS (Darwin) runners."
  exit 0
fi

if [[ ! -d "$WHISPER_DIR/.git" ]]; then
  rm -rf "$WHISPER_DIR"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
fi

cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DGGML_METAL=ON -DCMAKE_BUILD_TYPE=Release
cmake --build "$WHISPER_DIR/build" --config Release -j"$(sysctl -n hw.ncpu)"

# Prefer whisper-cli; fall back to main binary name differences across versions
if [[ -x "$WHISPER_DIR/build/bin/whisper-cli" ]]; then
  echo "whisper-cli ready: $WHISPER_DIR/build/bin/whisper-cli"
elif [[ -x "$WHISPER_DIR/build/bin/main" ]]; then
  ln -sfn "$WHISPER_DIR/build/bin/main" "$WHISPER_DIR/build/bin/whisper-cli"
  echo "aliased main -> whisper-cli"
else
  echo "ERROR: whisper binary not found under $WHISPER_DIR/build/bin" >&2
  ls -la "$WHISPER_DIR/build/bin" || true
  exit 1
fi

TINY="$MODELS/ggml-tiny.bin"
if [[ ! -f "$TINY" ]]; then
  curl -L --fail --progress-bar \
    -o "$TINY" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
fi

echo "Model: $TINY ($(du -h "$TINY" | awk '{print $1}'))"
