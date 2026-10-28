# Release readiness

Shelf is available as source for a native macOS application. The build targets macOS 14 or later and the architecture of the building Mac.

## Package

- Package, product and executable: `Shelf`.
- Bundle identifier: `com.baypeanut.Shelf`.
- Application output: `build/Shelf.app`.
- Data directory: `~/Library/Application Support/Shelf/Screenshots/`.
- Included resources: icon, localization, privacy manifest, privacy/security documents and dependency information.
- Optional visual-search builds include pinned model assets and their component notices.
- Update delivery is manual. No updater framework or credential helper is bundled.

The local builder uses ad-hoc signing with hardened runtime. Strict signature verification and an actual isolated AppKit launch are part of the build gate. Neither establishes notarization, Developer ID signing or Mac App Store approval.

## Distribution work

A direct-download release needs Developer ID signing, notarization, stapling and clean-machine Gatekeeper testing. App Store submission needs an App Sandbox implementation, entitlement and security-scoped folder review, screenshot-integration and direct-paste review, distribution provisioning, an Xcode archive and privacy declarations.

The privacy manifest must be checked against the final API usage and enabled features. A manifest alone does not establish qualification.

## Verification

Native tests use synthetic files, isolated preferences and private pasteboards. Bundle checks cover application identity, version, resources, model identity, runtime paths, signature integrity and startup. Secret scans cover the working tree and published history and include a positive detection control.

Results are recorded in [Validation](macos-validation.md), [Design](design.md), [Security review](security-review.md) and [Integration checks](integration-review.md). Personal data, build products, model downloads and test evidence stay outside Git.

Actual external-app paste, physical titlebar interaction, VoiceOver, long-duration energy use, Intel and the complete supported-OS matrix require further qualification. Local testing does not establish those results.
