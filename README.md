# Shelf

<img src="docs/assets/shelf-icon.png" width="96" height="96" alt="Shelf icon">

**Clipboard history for macOS, kept on your Mac.**

Shelf is a menu bar app for the images, text and links you copy. Open a shelf to find something recent, or save it to your Library with pins, folders and tags.

## What you can do

- Browse separate shelves for images, text and links.
- Search copied text, titles, tags, links and text inside images.
- Keep useful items with pins, folders and tags.
- Edit notes and annotate or crop images while preserving the originals.
- Copy a selection, drag it into another app or export a copy.
- Restore removed items from Library Trash.
- Use keyboard shortcuts and a searchable Actions menu.
- Enable optional offline visual search for image content.

Preview windows use the standard macOS close, minimize and zoom buttons at the top left. If an edit cannot be saved, you can retry, discard the edit or keep working.

## Build and run

You need **macOS 14 or later**, Xcode with the macOS SDK, and Python 3. The build targets your Mac's architecture. The current release has been tested locally on Apple silicon with Xcode 26.2 and Swift 6.2.3.

```sh
git clone https://github.com/baypeanut/shelf.git
cd shelf
bash scripts/build-community.sh release
open build/Shelf.app
```

The app is created at `build/Shelf.app`. Move it to your Applications folder to keep it installed.

This produces an ad-hoc signed local build. Developer ID signing, notarization and Mac App Store distribution are not configured. Updates are installed manually.

### Optional visual search

The default build includes local text recognition. To include offline image-content search as well:

```sh
SHELF_BUNDLE_MODELS=1 bash scripts/build-community.sh release
```

The first build downloads pinned model assets. Search runs on your Mac after the assets are bundled. Component details are in [Dependencies](DEPENDENCIES.md).

## First launch

Open **Settings → Sources** and choose what Shelf should capture. Clipboard image, text and link capture start disabled. Link previews have a separate switch because loading a preview contacts the saved website.

Shelf can watch the current macOS screenshot folder while it is running. You can choose additional folders. Inbox mode asks before changing your screenshot destination and restores the saved setting when disabled or on normal quit. Launch at login is optional.

## Keyboard shortcuts

| Action | Default shortcut |
| --- | --- |
| Show shelves | Control + Option + T |
| Navigate | Arrow keys |
| Preview the selected item | Space |
| Copy and return to your previous app | Return |
| Pin an item | P |
| File an item in a folder | Shift + P |
| Undo the latest shelf removal | Backspace |
| Open Actions | Command + K |

Shortcuts can be changed in Settings. Direct paste into another app requires macOS Accessibility permission. Ordinary copy does not.

## Privacy

There is no account, cloud sync, analytics or remote inference service. Your Library stays in `~/Library/Application Support/Shelf/Screenshots/`.

Capture skips supported confidential, concealed, transient and password-manager clipboard markers. Unmarked secrets cannot always be identified. Local history is protected by your macOS account permissions and is not encrypted by Shelf.

Link previews are off by default. When enabled, the destination website can see the request and your IP address. See [Privacy](PRIVACY.md) and [Security](SECURITY.md) for the complete behavior.

## Development

```sh
swift test
swift scripts/check-strings.swift
python3 scripts/test-audit-public.py
python3 scripts/test-release-version.py
python3 scripts/audit-public.py
python3 scripts/check-secrets.py
bash scripts/build-community.sh release
python3 scripts/verify-bundle.py build/Shelf.app
```

To inspect the interface with synthetic content and isolated preferences:

```sh
bash scripts/build-ui-tests.sh
open "build/Shelf UI Test.app"
```

Shelf uses Swift, AppKit, SwiftUI, Vision, Core ML and SQLite. Application code is in `Sources/Shelf`, regression tests are in `Tests`, and build tools are in `scripts`.

Read the [validation report](docs/macos-validation.md), [design notes](docs/design.md), [release checklist](docs/release-readiness.md) and [contribution guide](CONTRIBUTING.md) before making changes. Planned improvements are documented in the [workflow roadmap](docs/functional-review-workflows.md) and [macOS roadmap](docs/functional-review-macos.md).
