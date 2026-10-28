# macOS validation

Local environment: Apple silicon, macOS 26.6.2, Xcode 26.2 and Swift 6.2.3. The app targets macOS 14 or later. Hosted CI uses a separate macOS runner.

## Isolation

Tests use synthetic images, Unicode text, recording fixtures, disposable preference suites, test-owned folders and named pasteboards. They do not use personal clipboard history or change system screenshot preferences. Direct-paste tests inject accessibility operations rather than controlling personal applications.

The optional UI harness supports an isolated resumable profile, allowing an actual process restart to verify persistence without reseeding its fixtures.

## Native journeys

- Create a Unicode note, pin it, assign a folder/tag, restart and verify its identity, content and organization.
- Export a text snapshot, edit the item and verify the exported copy is unchanged.
- Move an item to recoverable Trash, undo, move it again and restore it from Trash.
- Switch grid/list, search empty and matching results, and edit a preview without losing the active search editor.
- Hold a write lock on the test database, verify that a failed save retains the draft, release the lock and retry/save/copy the exact text.
- Enable injected text/link capture, skip the old clipboard fixture, deduplicate repeats, route URLs to links and keep capture from stealing focus.
- Crop an 800×500 synthetic image to a 412×294 rendered copy while preserving its original. Exercise pen/shape drawing, undo/redo, save and reopen.
- Close and minimize native preview windows. Verify close recovery offers retry, discard and keep-editing options after a failed save.

## Regression coverage

The suite covers clipboard admission, bounded file writes, retention, data migration, text identity, organization, Trash/undo, export/drag payloads, keyboard routing, focus, markup/crops, recording trim, OCR caching, offline visual search and packaging policies.

Latest verification results:

| Check | Result |
| --- | --- |
| Full debug XCTest suite | 654 passed, no failures or skips |
| Full optimized XCTest suite | 651 passed, no failures or skips |
| Debug-only instrumentation cases | 3 |
| 10,000-record search benchmark | Maximum 3 ms in the recorded local run |
| Source publication guard tests | 4 passed |
| Release-version guard tests | 5 passed |
| Source and history secret scans | Passed, including positive detection controls |
| Packaged isolated launch, version 1.0.3 | Passed |

Two native event-dispatch regressions were reproduced before correction: a pointer event read a nonexistent key code, and the image canvas intercepted Enter before the crop command. The panel now checks the event type before accessing key data and lets image-canvas keys reach the preview router. The complete debug suite passed after the correction. Generated logs and app-window evidence stay in ignored local directories.

## Limits

Native button actions and accessibility actions were verified; coordinate input on the system titlebar was inconclusive in the automation session. Physical pointer input and actual VoiceOver use need separate manual qualification.

External-app Accessibility paste, permission continuity, clean-account installation, Intel execution and the complete supported-OS matrix are not established by these synthetic tests. Signing, notarization and App Store qualification remain separate release work.
