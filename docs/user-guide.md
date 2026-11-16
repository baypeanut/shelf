# Using Shelf

Shelf keeps recent images, text and links within reach from the menu bar. This guide follows a first session, from choosing capture sources to finding a saved item.

## Find the shelves

Open Shelf, then use Control + Option + T to show or hide the shelves with the default shortcut. A menu bar app can be running even when it has no ordinary document window open.

## Choose what to capture

In **Settings → Sources**, enable images, text or links individually. All three clipboard sources start disabled. Make a new copy after enabling a source; Shelf starts watching at the current clipboard change count.

## Pause or skip capture

Click the menu bar icon and choose **Pause Clipboard Capture** for 5 minutes, 1 hour or until you resume. The icon is struck through while capture is paused and the menu shows the time left, with **Resume Capture** below it. Nothing copied during a pause is added later. A pause that has not run out continues after you quit and reopen Shelf. **Skip Next Copy** ignores only the next thing you copy. The same commands are in Actions. Screenshots and watched folders keep working during a pause.

## Ignore an app

**Settings → Sources → Ignored apps** lists apps whose copies Shelf never captures. Use **Add App…** to pick one from Applications, or **Add a Running App**. The minus button removes an entry. For an item that shows a source app, **Ignore Copies from…** in Actions, in the Library list's context menu or in the inspector adds that app. Shelf identifies the app from the copy itself when the app declares it, and otherwise from the app in front at that moment, so a copy made in the background can be attributed to another app.

## See where a copy came from

Clipboard items record the app they were copied from. A preview shows it in its title bar and the Library inspector shows it under the date. In Library, **Filters → Copied from** limits the view to one app. Items captured before sources were recorded, screenshots and watched-folder images have none.

## Copy a link

A single web address is routed to Links. A paragraph that contains a link stays as text. Capturing the address and fetching its website title or thumbnail are separate settings.

## Choose link previews

**Fetch link titles and thumbnails** starts disabled. Enabling it contacts the linked website or supported public video service. Read [Privacy](../PRIVACY.md#network-requests) before enabling this for links you consider sensitive.

## Watch image folders

Shelf observes the current screenshot destination while running, subject to macOS folder access. **Also watch folders** accepts up to three extra folders. Removing a watched folder leaves its files untouched.

## Enable screenshot handling

**Handle screenshots** uses Inbox mode and asks before changing the screenshot destination. Disable the mode or quit normally to restore the saved setting. If Shelf is interrupted, reopen it so managed settings can be restored.

## Save something useful

Pin an item with P while browsing, or add it to a Library folder or tag. Favorites, folders and tags retain items beyond ordinary history expiry. [The Library guide](library-guide.md) explains the organization controls.

## Find an item

Use Shift + S to search the shelves, or open Library and use Command + F to search its current view. Check the active type and scope if an expected item is missing. Space previews the selection.

## Set a history window

**Settings → History** provides separate retention choices for images, texts and links. Unsaved copies expire to recoverable Library Trash. Saved items and original files are kept. **Items in Trash** sets how long Trash keeps them, 30 days by default, before they are permanently deleted; choose **Keep until Trash is emptied** to delete only by hand. A new period applies at the next cleanup, not at the moment you pick it. See [Troubleshooting](troubleshooting.md) for capture and search checks.
