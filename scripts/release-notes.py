#!/usr/bin/env python3
from pathlib import Path
import sys
notes = Path(__file__).resolve().parents[1]/'docs/releases'/(sys.argv[1]+'.md')
print(notes.read_text() if notes.is_file() else 'Improvements and fixes for Shelf.')
print('''
## Install

Download **Shelf-macOS-arm64.zip**, unzip it, and move **Shelf.app** to Applications.
Requires Apple silicon and macOS 14 or later. Offline visual search is included.

This community build is not signed with Apple Developer ID or notarized. macOS
may block its first launch. After attempting to open it, use **System Settings >
Privacy & Security > Open Anyway** if you trust the download.

Older builds without the updater need this one-time manual installation. Future
versions appear in Shelf's menu bar and **Settings > About**. No GitHub account
is needed. You choose when to download and install; edits must be saved before
restart. Your Library and capture preferences stay on your Mac.

The update feed and downloads are signed and verified using Sparkle's Ed25519 keys.
''')
