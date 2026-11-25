# Shelf privacy

Shelf stores captured text, images, links, the app each was copied from, titles, pins, folders, tags, annotations, OCR text and search vectors on your Mac. There is no Shelf account, telemetry, cloud history or remote inference service.

## Local storage

The independent application uses bundle identifier `com.baypeanut.Shelf` and `~/Library/Application Support/Shelf/Screenshots/`. It does not import another application's history. The SQLite library and managed files are restricted to your user account. Shelf does not encrypt the database; macOS account protection, FileVault and backup policy remain relevant. Other software running as your user may access this data.

Removing a shelf item can leave it in recoverable Library Trash. Pinned and organized records are retained.

Library Trash is emptied in two ways. Items that have been in Trash longer than the period chosen in **Settings → History** (30 days by default, or never) are permanently deleted during routine cleanup, including items that were already older than that when this behavior first ran. **Empty Trash…** in Library deletes everything in Trash after a confirmation that states the count. Neither can be undone. The deleted records, their search entries and their folder and tag links are removed from the database and overwritten there; files Shelf created for those items, and screenshots macOS saved into Shelf's folder in Inbox mode, move to the macOS Trash, where they stay until you empty it. Original files outside Shelf's storage are not touched.

Permanent deletion is not secure erasure of exports, originals, the macOS Trash, APFS snapshots or backups, including the backup Shelf made when it first created the Library. That backup holds Shelf's own preferences only and is removed after a week, or by **Empty Trash…**.

When an update changes how the Library is stored, Shelf first saves a copy of the database in `Library/Snapshots/` inside its storage folder, readable only by your account, so the change can be undone by hand. A copy holds everything the Library held at that moment, including items you permanently delete afterwards. Shelf keeps at most the two newest copies and deletes each one a week after it was made. **Empty Trash…** deletes every copy immediately; automatic cleanup of old Trash does not, so an item it removed can remain in a copy for up to that week. If a copy cannot be made, storage is left as it is and Shelf keeps working with it.

## Capture choices

Image, text and link clipboard capture are separate opt-ins and start disabled. Known confidential, transient, concealed and password-manager pasteboard markers are excluded. Link capture skips links that contain a user name or password, a recognized secret or signature parameter (including `;name=value` parameters), a signed token, or a key in the path such as a webhook, bot or sign-in token; such a copy is not kept as text either. Common parameter names such as `code`, `key`, `session` and `ticket` count as secret only when the value reads as random or the name is specific, such as `auth_code` or `api_key`, so links like `?promo_code=SAVE10` are still captured. Shelf cannot identify every unmarked password or token. Capture starts at the current pasteboard change count; launching does not import existing clipboard content.

## Source apps

When a clipboard copy is captured, Shelf records which app it came from: the app's bundle identifier and its display name, nothing else about the app or its windows. If the copy carries the `org.nspasteboard.source` pasteboard marker, Shelf uses the bundle identifier in it. Otherwise it records the app that is in front when Shelf notices the copy, up to half a second after it was made. That is a guess: a copy made by a background tool, or just before you switch apps, is attributed to whichever app was in front. Shelf does not record itself as a source, and screenshots and files from watched folders have no source.

The source is stored with the item in the same local SQLite library, shown in the item's details and preview, and can be used as a Library filter. It leaves your Mac only if you share the Library files yourself. Items captured before this was recorded have no source. Permanently deleting an item deletes its source with it.

**Settings → Sources → Ignored apps** lists apps whose copies are never captured. The list starts empty, holds only bundle identifiers and is kept in Shelf's preferences. A copy is skipped when its source, determined as above, is in the list, so the same guess applies: a copy an ignored app makes while another app is in front is captured unless it carries the source marker. Use it as a convenience, not as a guarantee for secrets.

## Pausing capture

**Pause clipboard capture** in the menu bar menu or Actions stops image, text and link capture for 5 minutes, 1 hour or until you resume. Nothing copied during a pause is captured, including after it ends. The end time is kept in Shelf's preferences, so a pause continues across a relaunch until it runs out or you resume. **Skip next copy** ignores the next single clipboard change. Neither affects screenshots or watched folders, which keep arriving while clipboard capture is paused.

## Screenshots and permissions

While running, Shelf observes the current macOS screenshot destination, subject to folder permissions. Additional watched folders are chosen separately. Inbox mode changes screenshot destinations only after consent and restores saved settings when disabled or on normal quit. A crash or force quit can prevent immediate restoration; reopen Shelf to restore its managed settings. Folder access is subject to macOS permission prompts.

Direct paste asks for Accessibility permission to return to the previously selected editable field. It checks field capabilities rather than reading the field's text. Ordinary copy does not need Accessibility permission. Opening links, exporting and pasting share the selected content with the application you choose.

## Network requests

Link enrichment starts disabled. Enabling it lets Shelf request metadata and thumbnails from captured public HTTPS URLs, including YouTube's public services for supported links. Those services see the request URL and your IP address. Requests reject credentials, recognized secret query parameters, single-use links such as sign-in, reset, verification, confirmation, recovery, activation, invitation and unsubscribe links (recognized by page names such as `/resetpassword.php` or `/verify-email-address`), parameters named only `code`, `key`, `session` or `ticket`, and private/reserved network destinations; DNS answers and redirects are validated, connections use validated addresses, and TLS checks the original host. HTML is parsed as bounded data, without executing JavaScript. Thumbnails are kept only as PNG, JPEG, GIF or WebP within the capture pixel limit.

Shelf has no in-app updater and makes no update checks. No GitHub credentials are requested. Downloading source, dependencies and optional pinned Core ML models occurs at build time. OCR and bundled model inference run locally.

## Privacy manifest

`packaging/PrivacyInfo.xcprivacy` declares no tracking or developer-collected data. It records use of local preferences, file timestamps for owned/user-selected files, and elapsed time for app operations. This manifest is packaged with the app. App Store privacy answers must be reviewed against the final distribution build and its enabled features.

For the corresponding controls and first-session steps, see [Using Shelf](https://github.com/baypeanut/shelf/blob/main/docs/user-guide.md). Review capture sources and link previews separately when deciding what to enable.
