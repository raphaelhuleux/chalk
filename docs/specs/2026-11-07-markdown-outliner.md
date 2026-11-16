# Markdown outliner

Status: normative for `.md` in editor-core.
When the policy changes, change this file first, then the handler, then its test.

## 1. What a subtree is

All outliner commands share one definition, in `md-outline-tree.ts` (`outlineNodeAt`).

- A **list item** (`-`, `*`, `+`, `N.`, `N)`, with or without a `[ ]` box) owns every following line that is indented deeper than it. A blank line stays inside only when a deeper line follows it. Trailing blank lines are outside.
- An **ATX or Setext heading** at the top level owns its section: everything up to the next heading of the same or a higher level, without the trailing blank lines (`headingSectionEnd`).
- A heading nested in a list or quote, and a callout's `## Title` line, are not nodes.
- A subtree never ends strictly inside a callout or a top-level block (display math, fenced code, table) that starts inside it; the end moves to that construct's last line. A node inside a callout never ends past the callout's last body line (`clampEnd`).
- Lines in fenced code, indented code and the frontmatter are never list items.

Siblings are the nearest nodes of the same kind and level with no shallower item, or same-or-higher heading, between them (`prevSibling`, `nextSibling`).

## 2. Folding

A fold hides a node's subtree from the end of its head line to the end of its last line (`md-fold.ts`, CodeMirror's `foldState`).
The head row shows a `…` placeholder; clicking it unfolds.
A chevron appears left of the marker when the pointer is over a foldable row, and stays on every folded row; clicking it toggles.
Folds are atomic, live outside the preview compartment and survive view-mode switches.
A selection head that lands strictly inside a fold unfolds it.
See section 7.1 of `2026-08-23-caret-and-reveal-semantics.md` for the motion rules.

## 3. Key policy

Mod is Cmd on macOS and Ctrl elsewhere.
"Falls through" means the handler returns false and the stock CodeMirror command runs.

| Key | Where | Does | Handler |
|---|---|---|---|
| Mod-Alt-[ | anywhere | folds the innermost unfolded node around the caret; again folds its parent | `foldAtCaret` |
| Mod-Alt-] | a folded head row | unfolds it | `unfoldAtCaret` |
| Mod-Alt-1 … 6 | anywhere | unfolds everything, then folds headings of that level and deeper; with no headings, list items at that nesting depth and deeper | `foldToLevel` |
| Mod-Alt-0 | anywhere | unfolds everything | `unfoldAll` |
| Mod-. | anywhere | zooms into the innermost node with children around the caret | `zoomIn` |
| Escape | zoomed, nothing else claims Escape | zooms out | `zoomOut` |
| Up / Down | next to a fold | crosses it in one press, keeps the goal column | `crossFold` |
| Enter | end of a folded head row | new line after the hidden subtree: a sibling marker for an item (next number, fresh `[ ] ` for a task), a plain line for a heading | `enterAfterFold` |
| Enter | a bullet item | continues the list tightly; an empty item leaves the list | `mdBulletEnterRun` |
| Tab / Shift-Tab | a list item, empty selection, outside math | indents / outdents the item with its subtree; an ordered item is renumbered at its new depth and the run it left closes the gap | `mdListIndentRun` |
| Tab / Shift-Tab | an ATX heading line | demotes / promotes the heading and every heading in its section; a no-op if any level would leave 1–6 | `shiftHeading` |
| Alt-Up / Alt-Down | a node's head line | swaps the subtree with the previous / next sibling; two ordered siblings keep their positions' numbers; folds move with their text; a no-op at the first / last sibling; falls through on any other line | `moveSubtree` |
| Backspace | right after an item's marker (and box) | a nested item outdents with its subtree; a top-level task loses its box; a top-level item loses its marker, and an ordered run closes the gap | `backspaceItem` |
| Backspace / Delete | one key from an empty caret that would delete into a fold | unfolds it and deletes nothing | `protectHidden` |
| typing / paste | at a fold's far edge (End on the head row) | inserts, and unfolds the fold, since the text lands on its last hidden line | `revealOnEdgeInput` |
| Mod-Enter | list items in the selection | steps a checkbox: no box → `[ ]` → `[x]` → `[ ]`; the first item picks the step for all; falls through with no item | `toggleTask` |
| Mod-Shift-8 / 7 / 9 | non-blank lines in the selection | makes bullets / a numbered list (counted per indent level) / tasks; headings lose their `#`s; when every line already is that type, they become plain lines | `setListType` |

Tab keeps its place in the chain: snippets, the completion popup and tab-out win first.
The fold guard on Up/Down yields to an open completion popup.

## 4. Indentation guides

A nested list draws a thin line from under each parent's marker to the last row of its subtree (`md-guides.ts`).
They are painted in a layer, never as decorations, so they hide nothing, add no caret stop and change no row height.
A folded item draws none.

## 5. Zoom

Zoom shows one node's subtree with a breadcrumb bar above it (`md-zoom.ts`); clicking a crumb zooms to that ancestor, "Document" zooms out.
Keyboard and pointer motion is clamped to the subtree; any other jump out of it (search, outline, cross-reference) ends the zoom.
Zoom is not saved.
