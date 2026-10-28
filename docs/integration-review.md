# Integration checks

Shelf is a macOS menu bar application with a local SQLite Library, managed files and optional metadata requests. Its bundle identifier is `com.baypeanut.Shelf`; managed history uses the Shelf application support directory.

## Files and persistence

Clipboard image writes pin the destination directory, reject symbolic links and create owner-only files exclusively. Failed writes remove the incomplete file. Library changes use transactions. Exports create copies and preserve external originals.

Text edits, image annotations and crops preserve item identity and organization. Save failures retain the active draft. Native close requests offer explicit recovery choices when saving fails.

## System integration

Inbox mode takes a recoverable snapshot of screenshot preferences before changing them. Restoration preserves later user edits. Native tests use injected preference stores and fictional paths; QA sessions do not register normal application termination cleanup.

Direct paste captures a target before Shelf takes keyboard focus, validates its capabilities and rechecks the target before sending the paste command. Native tests use injected accessibility operations and a private pasteboard. Real external-app paste and permission continuity require separate user-session testing.

## Packaging

The builder rejects symbolic-link output paths and unrelated existing application bundles. It includes localization, the privacy manifest, privacy/security documents and dependency information. Optional search assets include their own terms and acknowledgements.

The bundle verifier checks identity, version, resources, model identity, runtime paths and strict code-signature integrity. It executes `--check-launch`, which creates a synthetic AppKit window without opening a Library or reading a pasteboard.

## Release boundary

Developer ID signing, notarization, App Sandbox qualification, App Store submission, supported-OS coverage, VoiceOver and multi-display behavior require their own evidence. Results from the native suite and packaged launch are recorded in [Validation](macos-validation.md).
