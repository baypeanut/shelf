#!/usr/bin/env python3
"""Verify the actual packaged Shelf identity, resources and executable."""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/Shelf.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = json.loads((root / 'release-version.json').read_text())
expected = {'CFBundleIdentifier': 'com.baypeanut.Shelf', 'CFBundleName': 'Shelf',
            'CFBundleExecutable': 'Shelf', 'CFBundleShortVersionString': version['version'],
            'CFBundleVersion': version['build'], 'LSMinimumSystemVersion': '14.0'}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f'Unexpected bundle value: {key}')
if any(key in info for key in ('SUFeedURL', 'SUPublicEDKey')) or any(key.endswith('UpdateRepository') for key in info):
    raise SystemExit('Unconfigured update identity must not be packaged')
if any(info.get(key) is not False for key in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates')):
    raise SystemExit('Updater must be disabled')
resources = app / 'Contents/Resources'
for filename in ('Shelf.icns', 'DEPENDENCIES.md',
                 'PRIVACY.md', 'SECURITY.md', 'PrivacyInfo.xcprivacy', 'en.lproj/Localizable.strings',
                 'tr.lproj/Localizable.strings'):
    if not (resources / filename).is_file():
        raise SystemExit(f'Missing bundle resource: {filename}')
manifest = plistlib.loads((resources / 'PrivacyInfo.xcprivacy').read_bytes())
if manifest.get('NSPrivacyTracking') is not False:
    raise SystemExit('Unexpected tracking declaration')
models = resources / 'CLIP'
if models.exists():
    for filename in ('mobileclip_s2_image.mlmodelc', 'mobileclip_s2_text.mlmodelc', 'clip-vocab.json',
                     'clip-merges.txt', 'LICENSE-MobileCLIP-S2', 'LICENSE-Apple-code',
                     'ACKNOWLEDGEMENTS-MobileCLIP', 'model-source.json'):
        if not (models / filename).exists():
            raise SystemExit(f'Incomplete offline search bundle: {filename}')
    provenance = json.loads((models / 'model-source.json').read_text())
    if provenance.get('model') != 'MobileCLIP-S2' or provenance.get('revision') != '3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947':
        raise SystemExit('Unexpected offline model identity')
executable = app / 'Contents/MacOS/Shelf'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
linked = subprocess.check_output(['otool', '-L', str(executable)], text=True)
if 'Sparkle.framework/' in linked or (app / 'Contents/Frameworks/Sparkle.framework').exists():
    raise SystemExit('The disabled updater must not introduce a startup dependency')
if any('/Users/' in dependency for dependency in linked.splitlines()[1:]):
    raise SystemExit('Executable depends on a personal build path')
commands = subprocess.check_output(['otool', '-l', str(executable)], text=True)
for path in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+) \(offset', commands):
    if path.startswith('/') and path != '/usr/lib/swift':
        raise SystemExit('Executable retains a development-only runtime search path')
launch = subprocess.run([str(executable.resolve()), '--check-launch'],
                        capture_output=True, text=True, timeout=20)
if launch.returncode != 0 or launch.stdout.strip() != 'SHELF_LAUNCH_OK':
    # Dynamic-loader failures occur before main, even with a valid static
    # signature. Keep diagnostic output local and fail the release gate.
    sys.stderr.write(launch.stderr)
    raise SystemExit(f'Packaged application failed its launch check (exit {launch.returncode})')
print(f'Shelf {version["version"]} ({version["build"]}): bundle, resources, signature and actual isolated launch verified')
