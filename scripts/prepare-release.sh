#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(python3 -c 'import json; print(json.load(open("release-version.json"))["version"])')
BUILD=$(python3 -c 'import json; print(json.load(open("release-version.json"))["build"])')
TAG=${SHELF_RELEASE_TAG:-v$VERSION}
[ "$TAG" = "v$VERSION" ] || { echo 'Tag and release-version.json differ' >&2; exit 1; }
[ -n "${SHELF_UPDATE_KEY_FILE:-}" ] && [ -f "$SHELF_UPDATE_KEY_FILE" ] || { echo 'Set SHELF_UPDATE_KEY_FILE to the private release key' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo 'Public releases require an Apple silicon builder' >&2; exit 1; }
FEED="$PWD/build/feed-$VERSION"
UPLOAD="$PWD/build/upload-$VERSION"
[ ! -e "$FEED" ] && [ ! -e "$UPLOAD" ] || { echo 'Use a fresh release output; archives are immutable' >&2; exit 1; }
SHELF_UPDATES=1 SHELF_BUNDLE_MODELS=1 bash scripts/build-community.sh release
python3 scripts/check-release-version.py --expected-version "$VERSION" --app build/Shelf.app
mkdir -p "$FEED" "$UPLOAD"
ARCHIVE="Shelf-macOS-arm64-$VERSION-$BUILD.zip"
python3 scripts/archive-app.py build/Shelf.app "$FEED/$ARCHIVE"
if [ -f "docs/releases/$VERSION.md" ]; then cp "docs/releases/$VERSION.md" "$FEED/${ARCHIVE%.zip}.md"; fi
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$SPARKLE/generate_appcast" --ed-key-file "$SHELF_UPDATE_KEY_FILE" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "https://github.com/baypeanut/shelf/releases/download/$TAG/" "$FEED"
"$SPARKLE/sign_update" --ed-key-file "$SHELF_UPDATE_KEY_FILE" --verify "$FEED/appcast.xml"
python3 scripts/validate-update-feed.py "$FEED/appcast.xml" "$BUILD"
cp "$FEED/$ARCHIVE" "$UPLOAD/$ARCHIVE"
cp "$FEED/$ARCHIVE" "$UPLOAD/Shelf-macOS-arm64.zip"
cp "$FEED/appcast.xml" "$UPLOAD/appcast.xml"
(cd "$UPLOAD"; shasum -a 256 *.zip appcast.xml > SHA256SUMS)
echo "Verified release assets: $UPLOAD"
