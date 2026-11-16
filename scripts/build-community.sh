#!/bin/bash
# Build a self-contained Shelf app and check isolated startup. No install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-release}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: bash scripts/build-community.sh [debug|release]" >&2; exit 2 ;; esac
case "${SHELF_BUNDLE_MODELS:-0}" in 0|1) ;; *) echo "SHELF_BUNDLE_MODELS must be 0 or 1" >&2; exit 2 ;; esac
OUT="$ROOT/.build/packaging"
APP="$ROOT/build/Shelf.app"
STAGE="$OUT/Shelf.app"
for path in "$ROOT/.build" "$ROOT/build" "$OUT" "$APP" "$STAGE"; do
  if [ -L "$path" ]; then echo "Refusing symbolic-link build output: $path" >&2; exit 1; fi
done
mkdir -p "$OUT" "$ROOT/build"
if [ -e "$APP" ]; then
  python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
if not app.is_dir() or plistlib.loads((app/'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'com.baypeanut.Shelf':
    raise SystemExit('Refusing to replace a different application')
PY
fi
SWIFT_ARGS=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=.")
if [ "$CONFIG" = release ]; then SWIFT_ARGS+=(-Xswiftc -gnone); fi
swift build -c "$CONFIG" --product Shelf "${SWIFT_ARGS[@]}"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN/Shelf" "$STAGE/Contents/MacOS/Shelf"
python3 - "$STAGE/Contents/MacOS/Shelf" <<'PY'
import re, subprocess, sys
executable = sys.argv[1]
commands = subprocess.check_output(['otool', '-l', executable], text=True)
for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset', commands):
    if path.startswith('/') and path != '/usr/lib/swift':
        subprocess.run(['install_name_tool', '-delete_rpath', path, executable], check=True)
PY
for document in DEPENDENCIES.md PRIVACY.md SECURITY.md; do
  cp "$ROOT/$document" "$STAGE/Contents/Resources/$document"
done
cp "$ROOT/packaging/PrivacyInfo.xcprivacy" "$STAGE/Contents/Resources/PrivacyInfo.xcprivacy"
swift scripts/make-shelf-icon.swift "$OUT/icon.png"
ICONSET="$OUT/Shelf.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$OUT/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$OUT/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/Shelf.icns"
python3 - "$ROOT" "$STAGE" <<'PY'
import json, pathlib, plistlib, shutil, sys
root, app = map(pathlib.Path, sys.argv[1:])
version = json.loads((root/'release-version.json').read_text())
languages = []
for folder in sorted((root/'Sources/Shelf/Resources').glob('*.lproj')):
    languages.append(folder.stem)
    shutil.copytree(folder, app/'Contents/Resources'/folder.name)
info = {
    'CFBundleName': 'Shelf', 'CFBundleDisplayName': 'Shelf',
    'CFBundleIdentifier': 'com.baypeanut.Shelf', 'CFBundleExecutable': 'Shelf',
    'CFBundleIconFile': 'Shelf', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version['version'], 'CFBundleVersion': version['build'],
    'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': languages,
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
    'NSHighResolutionCapable': True, 'LSApplicationCategoryType': 'public.app-category.productivity',
    'NSDesktopFolderUsageDescription': 'Shelf reads images only from screenshot folders you choose.',
    'NSDocumentsFolderUsageDescription': 'Shelf reads images only from folders you choose.',
    'NSDownloadsFolderUsageDescription': 'Shelf reads images only from folders you choose.',
    'UTExportedTypeDeclarations': [{'UTTypeIdentifier': 'com.baypeanut.Shelf.library-item',
        'UTTypeConformsTo': ['public.data'], 'UTTypeDescription': 'Shelf library item identifier'}],
}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
if [ "${SHELF_BUNDLE_MODELS:-0}" = 1 ]; then bash scripts/bundle-search-models.sh "$STAGE"; fi

# Local ad-hoc signing is deliberately separate from Developer ID / App Store signing.
codesign --force --sign - --options runtime --timestamp=none "$STAGE"
codesign --verify --deep --strict "$STAGE"
if [ -d "$APP" ]; then rm -rf "$APP"; fi
ditto "$STAGE" "$APP"
python3 scripts/verify-bundle.py "$APP"
echo "Built: $APP"
echo "Isolated launch passed. Local build; not installed or started for normal use, notarized or submitted to the App Store."
