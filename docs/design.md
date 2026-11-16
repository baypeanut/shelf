# Interface

Shelf uses system typography, semantic colors, the system accent, native window controls and stock controls wherever one exists. The interface keeps copied content easy to scan without decorative motion. It has no palette of its own: nothing is tinted by content type, and there is no color setting.

`ShelfTheme.swift` holds the few values the custom surfaces share: four corner radii (panel 12, card 8, control 6, badge 4), the hairline, the card fill, the selection fill and the overlay fill. Buttons, menu items, tabs and window titles use title case in English and Turkish; labels and descriptions use sentence case.

## Shelves

Image, text and link rows share aligned headers and card insets. The active row's header has a neutral selection fill. Cards are flat, with a hairline edge and no shadow; a selected card has a ring in the system accent. Cards expose copy, preview and pin through keyboard commands and accessibility actions. Selection remains visible in light and dark appearance.

An opaque adaptive background keeps labels readable without sampling the desktop. Reduce Motion bypasses capture and removal travel and the fade of hover controls. Increase Contrast draws hairlines at full strength and one point wide and deepens the selection fill. Reduce Transparency replaces the material behind badges, notices and the search panel with the window color. `ShelfAccessibility.current` supplies these settings and can be replaced in tests.

## Library and Settings

Library uses a unified native toolbar, a resizable source-list sidebar, grid and list views, and an optional inspector. Its initial size is 1120 × 760 points, with an 870 × 560 minimum. The Library list uses the inset table style, and an empty view shows the system's content-unavailable state. Settings is a standard settings window: toolbar tabs for General, History, Sources, Keyboard Shortcuts and About, grouped forms, and the pane's name as the window title.

## Previews

Image, text, link and empty previews use native titlebars with close, minimize and zoom buttons at the top left. The window rounds its own corners; the content has none of its own. Image content retains its aspect ratio when the window or crop changes. Minimum content dimensions keep window controls reachable for small images.

The image toolbar provides drawing, shapes, text, cropping and undo/redo. Floating drawing controls accept the first click. Successful edits are saved before closing. A failed save presents retry, discard and keep-editing choices; cancelling preserves the draft.

## Actions and pickers

Actions, the folder and tag pickers and Name and Pin are floating panels with a HUD material and the panel radius. The selected Actions result is drawn in the system selection color with light text, as a menu draws it. The menu bar menu shows the Actions shortcut as a key equivalent.

## Icon

`scripts/make-shelf-icon.swift` draws the icon with Core Graphics. A picture, note and link rest on a dark grey shelf inside a light tile on the standard macOS icon grid, in system blue, white and orange. The build creates the application icon; `docs/assets/shelf-icon.png` is the documentation asset.

## Verification

Synthetic app-window inspection covered light/dark shelves, Library, Settings, image/text previews, markup and native close/minimize actions. `scripts/render-screens.sh` draws every screen to PNG files for review, as the [testing guide](testing-guide.md) describes. Native AppKit regressions cover window reuse, titlebar geometry, draft recovery, focus and undo/redo. Physical titlebar input and VoiceOver use still need separate manual qualification; accessibility action tests do not establish either.

The [preview guide](preview-guide.md) describes the user-facing editing tools, crop controls and close-recovery choices. Keep those instructions aligned with any changes to the preview interface.
