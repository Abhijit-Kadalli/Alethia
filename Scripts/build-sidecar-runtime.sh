#!/usr/bin/env bash
# Build a relocatable Apple Silicon Python runtime for the bundled ASR sidecar.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/.build/sidecar-runtime}"
PYTHON_VERSION="3.11.9"
PYTHON_BUILD="20240726"
ARCH="$(uname -m)"

if [[ "$(uname -s)" != "Darwin" || "$ARCH" != "arm64" ]]; then
  echo "The release sidecar runtime must be built on Apple Silicon macOS." >&2
  exit 1
fi

ARCHIVE="cpython-${PYTHON_VERSION}+${PYTHON_BUILD}-aarch64-apple-darwin-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD}/cpython-${PYTHON_VERSION}%2B${PYTHON_BUILD}-aarch64-apple-darwin-install_only.tar.gz"
CACHE="$ROOT/.build/downloads/$ARCHIVE"

mkdir -p "$(dirname "$CACHE")"
if [[ ! -f "$CACHE" ]]; then
  echo "Downloading standalone Python ${PYTHON_VERSION}…"
  curl --fail --location --retry 3 --output "$CACHE.part" "$URL"
  mv "$CACHE.part" "$CACHE"
fi

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
tar -xzf "$CACHE" -C "$OUTPUT"

PYTHON="$OUTPUT/python/bin/python3"
if [[ ! -x "$PYTHON" ]]; then
  echo "Standalone Python archive did not contain python/bin/python3." >&2
  exit 1
fi

"$PYTHON" -m pip install --disable-pip-version-check --upgrade pip
"$PYTHON" -m pip install --disable-pip-version-check \
  --requirement "$ROOT/Tools/crisperwhisper_sidecar/requirements.txt"

# Remove files that are only useful while developing the embedded runtime.
find "$OUTPUT/python" -type d \( -name __pycache__ -o -name tests -o -name test \) -prune -exec rm -rf {} +
find "$OUTPUT/python" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
rm -rf "$OUTPUT/python/lib/python3.11/site-packages/pip"* \
       "$OUTPUT/python/lib/python3.11/site-packages/setuptools"* \
       "$OUTPUT/python/lib/python3.11/site-packages/wheel"*

"$PYTHON" - <<'PY'
import crisperwhisper
import flask
import soundfile
import speechbrain
import torch
import torchaudio
import transformers
import waitress
print("Bundled sidecar imports verified.")
PY

du -sh "$OUTPUT/python"
