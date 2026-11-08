# Design notes

How Universal Converter is designed, and why. These follow Apple's Human Interface Guidelines. Keep to them when adding to the app.

## Principles

- **Clarity.** One job per element. A file row says what the file is, what it will become, and what happened. Nothing more.
- **Deference.** The files are the content. The interface stays out of the way: system fonts, system colors, standard controls.
- **Depth.** Layers show what is on top. Popovers hold detail. Materials separate bars from content.

## What is native, and why

| Part | Built with | Reason |
|---|---|---|
| Window title and file count | `navigationTitle` and `navigationSubtitle` | The system draws them, including in full screen and Mission Control. |
| Toolbar | `toolbar` | Gets Liquid Glass and customisation for free. Actions appear only when they can be used. |
| Empty state | `ContentUnavailableView` | The standard Apple empty state. A dashed drop box is a web habit, and Mac apps do not use it. |
| Dragging files in | `dropDestination` plus a highlight over the window | The same feedback Finder and Shortcuts give. |
| File list | `List` with the inset style | Gets selection, keyboard navigation, the Delete key and VoiceOver. |
| File thumbnails | Quick Look thumbnails | Files look the way they do in Finder. |
| Format choice | Pop-up `Picker` with sections | A pop-up is the Mac control for choosing one of many. |
| Bottom bar | `.bar` material | Content scrolls under it, and it adapts to light and dark. |
| Settings | `Settings` scene with a tab view | Opens with ⌘, and remembers its window. |
| Details and extra notes | Popovers | Detail on request, not in the way. |

## Rules for the file row

1. **One status line.** Show the most important note. "+N more" opens a popover with the rest.
2. **Colour never carries meaning alone.** Every state has a symbol: a triangle for caution, an octagon for blocked, a check for done.
3. **One primary action per state.** Convert, Cancel, Retry, Show in Finder.
4. **Controls line up.** Format pop-ups are right-aligned, so their right edges form a column.
5. **Plain words.** "Word document", not "Office Open XML word processing document".

## Colour, type and spacing

- System fonts only. Names use `.headline`, supporting text `.subheadline` and `.caption`.
- Semantic colours only (`.secondary`, `.tint`, `.orange`, `.red`, `.green`), so light, dark and increased contrast all work.
- One accent colour, the system's. It marks the single main action in each place.
- Spacing is a multiple of 2 and 4. Rows have 8 points above and below.

## Checking the design

`scripts/snapshot.sh` builds the app and saves pictures of its windows to `build/snapshots`, in light and dark mode. It runs the app with sample files in several states. Use it after any change to the interface.
