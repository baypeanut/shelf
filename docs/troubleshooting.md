# Troubleshooting Shelf

Start with a small reproduction containing fictional text or images. Record the Shelf version, macOS version and the action that failed before changing settings or rebuilding.

## No window appears

Shelf is a menu bar app. Try the default Control + Option + T shortcut and check whether Shelf is running before treating the absence of a document window as a launch failure. Custom shortcuts may differ from the defaults.

## The app does not launch

Verify the bundle using the commands in [Building Shelf](build-guide.md#verify-the-bundle). Confirm that you are opening the current packaged copy. Record the error and build version; keep crash reports local until you have checked them for private paths or content.

## A new copy is missing

Check the matching image, text or link switch in **Settings → Sources**, then make a fresh copy. Shelf skips existing clipboard contents at launch and supported sensitive markers. A single URL is routed to Links, while paragraphs remain text.

## Screenshots do not appear

Check the current screenshot destination and Shelf folder access. For an additional watched folder, confirm it is still listed under Sources. Test with a synthetic image in a test-owned folder; changing the system screenshot destination is unnecessary for that check.

## Search returns nothing

Clear the query, then check the sidebar scope, type filters and pinned-only state. Look in Library Trash if an item was removed or expired. Image-content search requires the optional model build, while text recognition is available in the default build.

## Direct paste fails

Try ordinary copy and paste first. Direct paste needs macOS Accessibility permission and an editable target in the previous app. Open the permission control from Shelf Settings and confirm that permission belongs to the installed copy you are using.
