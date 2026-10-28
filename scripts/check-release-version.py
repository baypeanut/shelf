#!/usr/bin/env python3
"""Validate Shelf's release version and, optionally, its built macOS bundle."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
STABLE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")

class ReleaseVersionError(ValueError):
    pass

def load_release_version(root: Path = ROOT) -> str:
    try:
        value = json.loads((Path(root) / "release-version.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseVersionError(f"Cannot read release-version.json: {error}") from error
    version = value.get("version") if isinstance(value, dict) else None
    if not isinstance(version, str) or not STABLE_VERSION.fullmatch(version):
        raise ReleaseVersionError("release-version.json version must be a stable major.minor.patch version")
    return version

def check_release_version(root: Path = ROOT, *, expected_version: str | None = None, app: Path | None = None) -> str:
    expected = load_release_version(root)
    if expected_version is not None and expected_version != expected:
        raise ReleaseVersionError("Selected version does not match release-version.json")
    if app is not None:
        try:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException) as error:
            raise ReleaseVersionError(f"Cannot read application Info.plist: {error}") from error
        if info.get("CFBundleIdentifier") != "com.baypeanut.Shelf":
            raise ReleaseVersionError("Application bundle identity is not Shelf")
        if info.get("CFBundleShortVersionString") != expected:
            raise ReleaseVersionError("Application version does not match release-version.json")
        build = info.get("CFBundleVersion")
        if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
            raise ReleaseVersionError("Application build must be a positive integer")
    return expected

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--expected-version")
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        version = check_release_version(args.root, expected_version=args.expected_version, app=args.app)
    except ReleaseVersionError as error:
        print(f"Release version check failed: {error}", file=sys.stderr)
        return 1
    print(f"Shelf release version {version}: valid" + ("; bundle version and identity match" if args.app else ""))
    return 0

if __name__ == "__main__":
    sys.exit(main())
