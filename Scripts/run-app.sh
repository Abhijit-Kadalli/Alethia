#!/usr/bin/env bash
# Developer loop: build, assemble Alethia.app at a stable path, and launch it.
#
# A stable path matters: macOS ties Accessibility / Microphone / Screen Recording grants
# to the signed bundle at that location, so rebuilding in place keeps permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${ALETHIA_INSTALL_DIR:-$HOME/Applications}"

cd "$ROOT"
if [[ ! -f App/AppIcon.icns ]]; then
  ./Scripts/build-app-icon.sh || echo "(icon skipped)"
fi

APP="$(ALETHIA_MAX_APP_BYTES=0 ./Scripts/package-app.sh "$ROOT/.build/package" | tail -n1)"
mkdir -p "$TARGET"
rm -rf "$TARGET/Alethia.app"
cp -R "$APP" "$TARGET/Alethia.app"
xattr -cr "$TARGET/Alethia.app" 2>/dev/null || true

pkill -x Alethia 2>/dev/null || true
open "$TARGET/Alethia.app"
echo "Launched $TARGET/Alethia.app"
