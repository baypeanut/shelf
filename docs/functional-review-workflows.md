# Workflow roadmap

These are proposed improvements, not features in the current release. Existing capabilities already include multi-selection, ordered batch copying, plain-text transfer, direct paste, pins, folders, tags, OCR, visual search, markup, cropping and individual exports.

| Priority | Improvement | Acceptance criteria |
| --- | --- | --- |
| 1 | Timed capture pause | Stop payload reads and new captures without changing permanent source choices. Resume with a fake clock, skip the existing clipboard and handle sleep/restart explicitly. |
| 2 | Saved searches | Save filters and queries as named views. Preserve exact Unicode and update results when item metadata changes. |
| 3 | Per-application capture exclusion | Pause capture while a selected application is active. Make uncertain source attribution visible and avoid silently retaining excluded content. |
| 4 | User-controlled paste queue | Let the user advance through selected items across editable fields. Revalidate the destination before every paste and allow cancellation without sending input. |
| 5 | Portable Library backup and restore | Include files, organization and edits in a versioned archive. Validate paths, checksums, conflicts and rollback before committing a restore. |
| 6 | Text merge and transform preview | Preview the exact output before copying. Support ordered merging and small text operations while leaving original items intact. |

## Relevant code

Capture policy belongs near `AppDelegate`, `ClipboardWatcher` and `TextClipboardWatcher`. Saved views build on `LibraryQuery` and `LibraryModel`. Paste queues must retain the target checks in `DirectPasteCoordinator`. Backup and restore need transactional boundaries in `LibraryStore` and the file-ownership rules in `HistoryFiles`.

Every proposal should be tested with synthetic content, injected clocks and private pasteboards. No feature should require personal clipboard data for development or silently change capture permissions.
