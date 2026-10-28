#!/bin/bash
# Build only: synthetic data, isolated preferences, no real clipboard watcher.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ] && [[ "$DEVELOPER_DIR" == /Library/Developer/CommandLineTools* ]] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
OUT="$PWD/.build/ui-tests"
APP="$PWD/build/Shelf UI Test.app"
python3 - "$APP" <<'PY'
import pathlib,subprocess,sys
executable=str(pathlib.Path(sys.argv[1])/'Contents/MacOS/FeatureTests')
commands=subprocess.check_output(['ps','-A','-o','comm='],text=True).splitlines()
if executable in [command.strip() for command in commands]:
    sys.exit('UI harness is running. Quit it before rebuilding its bundle.')
PY
mkdir -p "$OUT/ModuleCache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
for source in Sources/Shelf/*.swift; do
  [[ "$source" == */main.swift ]] || SOURCES+=("$source")
done
case "${SHELF_UI_CONFIGURATION:-release}" in
  release) UI_OPT=(-O) ;;
  debug) UI_OPT=(-Onone) ;;
  *) echo "SHELF_UI_CONFIGURATION must be debug or release" >&2; exit 2 ;;
esac
swiftc "${UI_OPT[@]}" -g -file-prefix-map "$PWD=." -sdk "$SDK" -module-cache-path "$OUT/ModuleCache" \
  -D STANDALONE_TESTS -parse-as-library "${SOURCES[@]}" \
  Tests/ImageHistoryTests/TestFixtures.swift Tests/UITests/UIHarness.swift \
  -o "$APP/Contents/MacOS/FeatureTests"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib,sys,shutil,json,subprocess
app=Path(sys.argv[1])
state=json.loads(Path("release-version.json").read_text())
revision=subprocess.run(['git','rev-parse','--verify','HEAD'],text=True,capture_output=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'com.baypeanut.Shelf.uitests',
    'CFBundleName':'Shelf UI Test',
    'CFBundleDisplayName':'Shelf UI Test',
    'CFBundleExecutable':'FeatureTests',
    'CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':state['version'],
    'CFBundleVersion':'1',
    'CFBundleIconFile':'Shelf',
    'ShelfSourceRevision':revision.stdout.strip() if revision.returncode == 0 else 'working-tree',
    'LSMinimumSystemVersion':'14.0',
    'NSHighResolutionCapable':True,
    'UTExportedTypeDeclarations':[{'UTTypeIdentifier':'com.baypeanut.Shelf.library-item','UTTypeConformsTo':['public.data'],'UTTypeDescription':'Library item identifier'}],
}))
for resource in Path('Sources/Shelf/Resources').glob('*.lproj'):
    shutil.copytree(resource,app/'Contents/Resources'/resource.name,dirs_exist_ok=True)
PY
if [ "${SHELF_BUNDLE_MODELS:-0}" = "1" ]; then
  bash scripts/bundle-search-models.sh "$APP"
fi
swift scripts/make-shelf-icon.swift "$OUT/Shelf.png"
sips -z 512 512 "$OUT/Shelf.png" --out "$OUT/Shelf512.png" >/dev/null
python3 - "$OUT" "$APP/Contents/Resources/Shelf.icns" <<'ICONPY'
from pathlib import Path
import struct, sys
root, destination = map(Path, sys.argv[1:])
chunks = []
for kind, filename in [(b'ic09', 'Shelf512.png'), (b'ic10', 'Shelf.png')]:
    data = (root / filename).read_bytes()
    chunks.append(kind + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
destination.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
ICONPY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (not launched)"
