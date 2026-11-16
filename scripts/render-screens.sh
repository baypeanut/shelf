#!/bin/bash
# Draws every screen of the synthetic UI harness into PNG files, in light and
# dark appearance, without showing a window. Works while the screen is locked.
# Usage: bash scripts/render-screens.sh <output folder> [language ...]
set -euo pipefail
cd "$(dirname "$0")/.."
if [ $# -lt 1 ]; then
  echo "usage: bash scripts/render-screens.sh <output folder> [language ...]" >&2
  exit 2
fi
mkdir -p "$1"
OUT="$(cd "$1" && pwd)"
shift
LANGUAGES=("$@")
if [ ${#LANGUAGES[@]} -eq 0 ]; then LANGUAGES=(en tr); fi
APP="$PWD/build/Shelf UI Test.app"
if [ "${SHELF_RENDER_SKIP_BUILD:-0}" != "1" ]; then bash scripts/build-ui-tests.sh >/dev/null; fi
for language in "${LANGUAGES[@]}"; do
  if [ ! -d "Sources/Shelf/Resources/$language.lproj" ]; then
    echo "No translation named $language" >&2
    exit 2
  fi
  # The language applies to this run only; nothing is written to preferences.
  "$APP/Contents/MacOS/FeatureTests" --render-screens "$OUT" -AppleLanguages "($language)"
  echo "Rendered $language into $OUT"
done
