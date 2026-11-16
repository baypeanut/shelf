# Shelf privacy

Shelf stores captured text, images, links, titles, pins, folders, tags, annotations, OCR text and search vectors on your Mac. There is no Shelf account, telemetry, cloud history or remote inference service.

## Local storage

The independent application uses bundle identifier `com.baypeanut.Shelf` and `~/Library/Application Support/Shelf/Screenshots/`. It does not import another application's history. The SQLite library and managed files are restricted to your user account. Shelf does not encrypt the database; macOS account protection, FileVault and backup policy remain relevant. Other software running as your user may access this data.

Removing a shelf item can leave it in recoverable Library Trash. Pinned and organized records are retained.

Library Trash is emptied in two ways. Items that have been in Trash longer than the period chosen in **Settings → History** (30 days by default, or never) are permanently deleted during routine cleanup, including items that were already older than that when this behavior first ran. **Empty Trash…** in Library deletes everything in Trash after a confirmation that states the count. Neither can be undone. The deleted records, their search entries and their folder and tag links are removed from the database and overwritten there; files Shelf created for those items move to the macOS Trash, where they stay until you empty it. Original files outside Shelf's storage are not touched.

Permanent deletion is not secure erasure of exports, originals, the macOS Trash, APFS snapshots or backups, including the backup Shelf made when it first created the Library.

## Capture choices

Image, text and link clipboard capture are separate opt-ins and start disabled. Known confidential, transient, concealed and password-manager pasteboard markers are excluded. Shelf cannot identify every unmarked password or token. Capture starts at the current pasteboard change count; launching does not import existing clipboard content.

While running, Shelf observes the current macOS screenshot destination, subject to folder permissions. Additional watched folders are chosen separately. Inbox mode changes screenshot destinations only after consent and restores saved settings when disabled or on normal quit. A crash or force quit can prevent immediate restoration; reopen Shelf to restore its managed settings. Folder access is subject to macOS permission prompts.

Direct paste asks for Accessibility permission to return to the previously selected editable field. It checks field capabilities rather than reading the field's text. Ordinary copy does not need Accessibility permission. Opening links, exporting and pasting share the selected content with the application you choose.

## Network requests

Link enrichment starts disabled. Enabling it lets Shelf request metadata and thumbnails from captured public HTTPS URLs, including YouTube's public services for supported links. Those services see the request URL and your IP address. Requests reject credentials, recognized secret query parameters and private/reserved network destinations; DNS answers and redirects are validated, connections use validated addresses, and TLS checks the original host. HTML is parsed as bounded data, without executing JavaScript.

Shelf has no in-app updater and makes no update checks. No GitHub credentials are requested. Downloading source, dependencies and optional pinned Core ML models occurs at build time. OCR and bundled model inference run locally.

## Privacy manifest

`packaging/PrivacyInfo.xcprivacy` declares no tracking or developer-collected data. It records use of local preferences, file timestamps for owned/user-selected files, and elapsed time for app operations. This manifest is packaged with the app. App Store privacy answers must be reviewed against the final distribution build and its enabled features.

For the corresponding controls and first-session steps, see [Using Shelf](https://github.com/baypeanut/shelf/blob/main/docs/user-guide.md). Review capture sources and link previews separately when deciding what to enable.
