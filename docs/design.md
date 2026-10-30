# Interface

Shelf uses system typography, semantic colors, native window controls and restrained content accents. The interface keeps copied content easy to scan without decorative motion.

## Shelves

Image, text and link rows share aligned headers and card insets. The active row has a subtle tint. Cards expose copy, preview and pin through keyboard commands and accessibility actions. Selection remains visible in light and dark appearance.

An opaque adaptive background keeps labels readable without sampling the desktop. Reduce Motion bypasses capture and removal travel. Type accents have separate values for light and dark appearance.

## Library and Settings

Library uses a unified native toolbar, a resizable source-list sidebar, grid and list views, and an optional inspector. Its initial size is 1120 × 760 points, with an 870 × 560 minimum. Settings groups source, history, appearance and keyboard controls in a native window.

## Previews

Image, text, link and empty previews use native titlebars with close, minimize and zoom buttons at the top left. Image content retains its aspect ratio when the window or crop changes. Minimum content dimensions keep window controls reachable for small images.

The image toolbar provides drawing, shapes, text, cropping and undo/redo. Floating drawing controls accept the first click. Successful edits are saved before closing. A failed save presents retry, discard and keep-editing choices; cancelling preserves the draft.

## Icon

`scripts/make-shelf-icon.swift` draws the icon with Core Graphics. A picture, note and link rest on a graphite shelf inside an ivory tile. The build creates the application icon; `docs/assets/shelf-icon.png` is the documentation asset.

## Verification

Synthetic app-window inspection covered light/dark shelves, Library, Settings, image/text previews, markup and native close/minimize actions. Native AppKit regressions cover window reuse, titlebar geometry, draft recovery, focus and undo/redo. Physical titlebar input and VoiceOver use still need separate manual qualification; accessibility action tests do not establish either.

The [preview guide](preview-guide.md) describes the user-facing editing tools, crop controls and close-recovery choices. Keep those instructions aligned with any changes to the preview interface.
