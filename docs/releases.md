# Publishing Shelf

Ordinary pushes do not publish updates. Stable version tags start the release
workflow, which runs native debug and release tests, source security checks,
localization and bundle validation, and real Sparkle installation tests.

## Publish a version

1. Update `release-version.json` on `main`. For version `1.1.1`, use build `1001001`.
2. Add optional notes at `docs/releases/1.1.1.md`, then commit and push the changes.
3. Send the matching tag:

```sh
git tag -a v1.1.1 -m "Shelf 1.1.1"
git push origin v1.1.1
```

Tags must be `vMAJOR.MINOR.PATCH`, without suffixes or leading zeros. Components
are 0 through 999. The build number is `MAJOR * 1000000 + MINOR * 1000 + PATCH`.
The tag must belong to `main` and match the version file. Existing release tags
and versions older than the latest stable release are rejected.

All assets are uploaded to a draft release before it becomes public. A failed
check prevents publication. Inspect and delete an incomplete unpublished draft
before retrying. Never replace published archives or move published tags. Revert
faulty code and release a higher version when a rollback is necessary.

## Signing

The private Ed25519 key lives in the repository secret `SHELF_UPDATE_PRIVATE_KEY`.
It is written to a restricted temporary file only in the publishing job, then
removed. Keep a separate safe backup. Losing or casually rotating this key can
prevent installed copies from accepting future updates. The public key and feed
are in `packaging/Updates.plist`. Never share another app's signing key with Shelf.

Sparkle verifies both the feed and archive. Code uses ad-hoc signatures and the
hardened runtime, with a narrow library-validation exception for the updater.
This does not establish Apple Developer ID signing, notarization or App Store
approval. First-launch Gatekeeper warnings are expected. Users can use System
Settings > Privacy & Security > Open Anyway after attempting to open a trusted
download. Do not disable Gatekeeper or alter Keychain trust.

## Local package and tests

```sh
export SHELF_UPDATE_KEY_FILE=/secure/path/to/update-signing.key
bash scripts/prepare-release.sh
python3 scripts/test-update-install.py
```

The package command requires Apple silicon, includes offline visual search, and
writes immutable assets to `build/upload-VERSION`. `Shelf-macOS-arm64.zip` is the
manual download; the appcast uses the versioned archive. SHA256SUMS accompanies
both archives and the appcast.

The integration tests use disposable applications, keys and preferences. They
exercise actual install/relaunch and verify that modified feeds and archives are
rejected without replacing the original app. They never read clipboard history
or change screenshot preferences.

The first update-enabled release must be installed manually over older local
builds. Future releases appear quietly in the menu bar and Settings > About.
Users choose when to install, and active operations finish before restart. Normal
termination checks still flush edits and refuse to quit if they cannot be saved.
The Library and capture preferences remain outside the application bundle.
