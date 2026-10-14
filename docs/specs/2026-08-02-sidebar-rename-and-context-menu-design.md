# Sidebar: inline rename and a full context menu

Date: 2026-08-02
Status: approved, ready for an implementation plan

## Problem

Two gaps in the Library sidebar:

1. Renaming opens a `UIAlertController`. Every modern file manager edits the
   name in place. The dialog also breaks the reading position: the tree is
   covered while the user types the name of a row they can no longer see.
2. The right-click menu carries four items (Open or New File/New Folder,
   Rename, Copy Path). The operations a file manager is expected to have —
   open in a new tab, open in a new window, duplicate, copy, move to trash —
   are missing, so those tasks leave the app.

## Decisions taken

- **Copy** puts the *file* on the system pasteboard, so Cmd+V pastes a real
  file into Finder or Files. `Copy Path` stays as the separate text variant.
  No Paste action in the sidebar (not requested; avoids collision and
  cross-Location policy).
- **Move to Trash** is immediate, no confirmation. Cmd+Z restores it. This
  matches Finder and keeps the "no dialogs" direction of the rename work.
- **Rename triggers** are slow double-click, F2, and the context menu.
  Return keeps activating a row (opens files, toggles folders) as the
  keyboard-nav work just shipped it.

## 1. Inline rename

`renamingNode: FileNode?` joins `hoveredNode`, `dropTargetNode`, and the focus
state as cell-registration input, so the repaint path is the existing one
(`repaintRows`, `setNeedsUpdateConfiguration`).

The editing row swaps `UIListContentConfiguration` for a small custom content
view holding the row icon and a `UITextField`. It reuses the row font,
`compactRowMargins`, and the selection pill, so the label-to-field swap has no
jump in position or weight. A `ChalkMetrics.motionFast` cross-fade covers the
swap.

Behavior:

- The base name is preselected; the extension is kept.
- Enter commits. Esc cancels. Tapping another row, scrolling, or losing window
  focus commits (a started rename is not lost).
- A rejected name keeps the editor open and shakes the field. No alert. Reject
  when the name is empty, unchanged, contains `/`, starts with `.`, or collides
  with an existing sibling. Case-only renames are allowed
  (`FileMove.isCaseOnlyRename`).
- Enter on a rejected name keeps the editor open; blur on a rejected name
  cancels and restores the old name. Blur must never trap the user in a row
  they cannot leave.
- Commit goes through `moveFile`, so coordinated moves, open-tab remapping
  (`onFileMoved`), and Cmd+Z all keep working unchanged.
- The reload after a commit animates, so the row slides to its new sorted
  position (folders first, then case-insensitive by name).

Slow double-click: a second click on an already-selected row, between 0.4s and
2.5s after the first, with the pointer within a few points of the first. The
second click also re-opens the file, which is a no-op because it is already the
active tab.

## 2. Context menu

File row:

```
Open · Open in New Tab · Open in New Window
Rename · Duplicate · Copy · Copy Path
New File · New Folder          (in the containing folder)
Move to Trash                  (destructive)
```

Folder row:

```
New File · New Folder          (inside this folder)
Rename · Duplicate · Copy · Copy Path
Move to Trash                  (destructive)
```

Groups are inline `UIMenu` sections so the separators match the rest of the
app. Folders get no "Open in New Window" (a folder is not a document). The
Location header menu is unchanged. The "Empty" sentinel row stays inert.

`Open` keeps today's browse-reuse behavior: it replaces the current tab when
that tab is unmodified. `Open in New Tab` always adds a tab. The two differ
only in that reuse.

## 3. File mutations

| Action | Implementation | Undo |
| --- | --- | --- |
| Duplicate | `copyItem` to the next free `name 2.ext` via the existing `uniqueURL` convention | trashes the copy |
| Move to Trash | `FileManager.trashItem`, capturing the resulting trash URL | moves it back |
| Copy | `UIPasteboard.general.itemProviders = [NSItemProvider(contentsOf:)]` | none (pasteboard) |
| Copy Path | unchanged | none |

All mutations register with the existing `fileUndoManager` and report failures
through `showFileOpFailure`, matching rename and drag-move. `trashItem` can
fail inside a sandbox; that failure surfaces as a message rather than silence.

## 4. Open in New Window

Reuses `ChalkActivity.newWindowType`, carrying the file URL in the activity's
`userInfo`. `SceneLaunchPolicy` already sends a new-window request to
`.openEmpty`, so it needs no change; `SceneDelegate` reads the URL after the
root view controller exists and calls the existing
`RootSplitViewController.openExternalDocument`, which takes the security scope
and reveals the editor column.

"Open in New Tab" is `editor.open(url:)` with no clean-tab reuse, the call
`onOpenCreatedFile` already makes. It needs a new sidebar callback so a menu
action can ask for a tab without the browse-reuse behavior.

## 5. Code organization

`SidebarViewController.swift` is 74k and grew again with keyboard navigation.
This work adds a menu builder, four mutations, and a rename editor, so it
splits along existing seams:

- `mac/Chalk/Sidebar/SidebarFileOperations.swift` — create, duplicate, trash,
  copy, and the context-menu builder.
- `mac/Chalk/Sidebar/SidebarRenameEditor.swift` — the editing content view and
  the rename lifecycle.

Both are extensions on `SidebarViewController`, so no call sites move and no
state changes owner.

Pure rules go to ChalkKit beside `FileMove`:

- `FileNaming.validateRename(_:)` — the reject list above.
- `FileNaming.uniqueName(base:ext:isTaken:)` — the `name 2` convention, with
  the filesystem check injected.
- `RenameGesture.shouldBeginRename(sameRow:interval:distance:)` — the
  slow-double-click timing rule.

## 6. Testing

ChalkKit (`swift test`, no simulator):

- name validation: empty, unchanged, `/`, leading dot, case-only rename allowed
- duplicate naming: `draft.tex` to `draft 2.tex`, then `draft 3.tex`; names
  without an extension; names with several dots
- click timing: too fast, in range, too slow, different row, pointer moved

ChalkTests:

- menu composition: exact titles and order for a file row and a folder row;
  the sentinel row still has no menu
- rename lifecycle against a temp directory: begin shows the field, commit
  renames on disk and updates the row, Esc leaves the file alone, a colliding
  name keeps the editor open and changes nothing on disk
- duplicate and trash, each followed by undo, asserted against the filesystem;
  trash tests `XCTSkip` if the sandbox refuses `trashItem`

## Risks

- Slow double-click can fire during ordinary browsing, because a click in this
  sidebar opens a file rather than only selecting it. The timing window,
  same-row requirement, and pointer-distance guard narrow it; F2 and the menu
  remain the deliberate paths. If it proves annoying in use, the trigger can be
  dropped without touching the rest of the rename work.
- `NSItemProvider(contentsOf:)` may copy file contents rather than a reference
  for large files. Acceptable for `.md`/`.tex`.
- The rename editor must commit rather than vanish when the tree reloads
  underneath it (an iCloud change or another window's edit). The commit-on-blur
  rule covers it; a reload that removes the renaming row cancels the editor.
