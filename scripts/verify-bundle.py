#!/usr/bin/env python3
"""Verify the actual packaged Shelf identity, resources, signature and executable."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
MODEL_REVISION = '3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947'
COMPILED_MODELS = ('mobileclip_s2_image.mlmodelc', 'mobileclip_s2_text.mlmodelc')
ASSET_HASHES = {'clip-vocab.json': '7aeb221a2a93047170070379743b49204c13d6993d9947323cd94b75c1f657ba', 'clip-merges.txt': '7e0847f6fced8bd28a736dcaeab20e64ac19010771700197ba479a0a8e517d4f', 'LICENSE-MobileCLIP-S2': 'a94a7a9c59509751580a31fa1ab3b418a97b01304549d382b8b96ca8fa85a179', 'LICENSE-Apple-code': '7be983907ac2fa52c53e29ad8eca89d67d1e77bcc46a0271702845d0a1f4114d', 'ACKNOWLEDGEMENTS-MobileCLIP': '1fdf63aae2e325e2efde1aed1d3cc9addb063ea60a31f40d2a564bd7c29ac283'}
# Code that macOS loads from inside a bundle. Shelf ships one executable only.
NESTED_CODE = ('Frameworks', 'PlugIns', 'XPCServices', 'Library', 'Helpers')
# Thin 32- and 64-bit, and universal with 32- and 64-bit offsets, in both byte orders.
MACH_O = {b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe',
          b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def tree_manifest(folder):
    """SHA-256 of every file by relative path; None when the tree holds a link or special file."""
    if folder.is_symlink() or not folder.is_dir():
        return None
    manifest = {}
    for directory, folders, names in os.walk(folder):
        for name in folders + names:
            path = Path(directory) / name
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                return None
        for name in names:
            path = Path(directory) / name
            manifest[path.relative_to(folder).as_posix()] = sha256(path)
    return manifest


def check_models(models):
    for filename in COMPILED_MODELS + ('clip-vocab.json', 'clip-merges.txt', 'LICENSE-MobileCLIP-S2', 'LICENSE-Apple-code',
                                       'ACKNOWLEDGEMENTS-MobileCLIP', 'model-source.json'):
        if not (models / filename).exists():
            raise SystemExit(f'Incomplete offline search bundle: {filename}')
    provenance = json.loads((models / 'model-source.json').read_text())
    if provenance.get('model') != 'MobileCLIP-S2' or provenance.get('revision') != MODEL_REVISION:
        raise SystemExit('Unexpected offline model identity')
    for name, expected in ASSET_HASHES.items():
        if provenance.get('sha256', {}).get(name) != expected or sha256(models / name) != expected:
            raise SystemExit('Bundled asset checksum mismatch: ' + name)
    # The preparation step records these after compiling the pinned packages.
    compiled = provenance.get('compiled')
    if not isinstance(compiled, dict) or set(compiled) != set(COMPILED_MODELS):
        raise SystemExit('Compiled model checksums are missing')
    for name in COMPILED_MODELS:
        expected = compiled[name]
        if not isinstance(expected, dict) or not expected or tree_manifest(models / name) != expected:
            raise SystemExit('Bundled compiled model checksum mismatch: ' + name)


def check_signature(app):
    details = subprocess.run(['codesign', '-d', '--verbose=2', str(app)], capture_output=True, text=True, check=True).stderr
    flags = re.search(r'^CodeDirectory .*\bflags=0x[0-9a-f]+\(([^)]*)\)', details, re.M)
    if not flags or 'runtime' not in flags.group(1).split(','):
        raise SystemExit('The app is not signed with the hardened runtime')
    entitlements = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)], capture_output=True, check=True).stdout
    if entitlements.strip() and plistlib.loads(entitlements):
        raise SystemExit('The app must not carry entitlements')
    contents = app / 'Contents'
    for name in NESTED_CODE:
        if os.path.lexists(contents / name):
            raise SystemExit(f'Nested code is not expected: Contents/{name}')
    executables = sorted(path.name for path in (contents / 'MacOS').iterdir())
    if executables != ['Shelf']:
        raise SystemExit('Contents/MacOS must hold only the Shelf executable')
    for directory, folders, names in os.walk(contents):
        for name in folders + names:
            path = Path(directory) / name
            if path.is_symlink():
                raise SystemExit('Symbolic links are not expected in the bundle: ' + path.relative_to(app).as_posix())
            if path.is_file() and path != contents / 'MacOS/Shelf':
                # Resources and models are data; a script or tool would need an execute bit.
                if path.stat().st_mode & 0o111:
                    raise SystemExit('Executable files are not expected outside Contents/MacOS: ' + path.relative_to(app).as_posix())
                with open(path, 'rb') as handle:
                    if handle.read(4) in MACH_O:
                        raise SystemExit('Nested code is not expected: ' + path.relative_to(app).as_posix())


def main():
    app = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'build/Shelf.app'
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version = json.loads((root / 'release-version.json').read_text())
    expected = {'CFBundleIdentifier': 'com.baypeanut.Shelf', 'CFBundleName': 'Shelf',
                'CFBundleExecutable': 'Shelf', 'CFBundleShortVersionString': version['version'],
                'CFBundleVersion': version['build'], 'LSMinimumSystemVersion': '14.0'}
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit(f'Unexpected bundle value: {key}')
    # Shelf has no in-app updater, so no update feed, key or preference belongs here.
    if any(key.startswith('SU') or key.endswith('UpdateRepository') for key in info):
        raise SystemExit('Update settings must not be packaged')
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
        check_models(models)
    executable = app / 'Contents/MacOS/Shelf'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    check_signature(app)
    linked = subprocess.check_output(['otool', '-L', str(executable)], text=True)
    if 'Sparkle.framework/' in linked or (app / 'Contents/Frameworks/Sparkle.framework').exists():
        raise SystemExit('An updater framework must not be packaged')
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


if __name__ == '__main__':
    main()
