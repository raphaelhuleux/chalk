# Blank editor when opening a file (Catalyst)

Status: **fixed, 2026-07-26.** Root cause confirmed and closed — see "Resolution" at the end. Filed 2026-07-24 after the tab-strip pairing work; blocked core use.

## Symptom

Clicking a file in the sidebar (or opening one any other way) creates the tab —
the strip chip shows the filename with its dirty/preview styling — but the
editor body stays on the "No document open" placeholder. The document itself is
fine; the tab's editor surface is just never shown in the window you are looking
at. `Ctrl+Tab` still cycles tabs, confirming the tabs model is intact and only
the visible surface is missing.

## Evidence gathered this session (all from the deployed Release/Debug build)

Confirmed:

- On a **fully clean launch** (Saved Application State purged first), opening
  `Welcome.md` produced a window whose chip read "Welcome.md" while the body
  showed "No document open / Open a file from the Library, or press ⌘N".
  Screenshot: scratch `one-big.png`.
- That same clean launch **spawned four windows** (one 2544×1399 main + three
  1024×768). macOS is reconnecting scene sessions the app allows even though
  saved window state was purged.
- Under the multi-window storm a **second, distinct** failure appears in the
  log: `[com.huleux.chalk:doc] failed to open` — `ChalkDocument.open` returns
  `success == false`, driven by `grantAccessClaim reply is an error … Code=24
  "Too many open files"` (file-descriptor exhaustion: N windows each spin up a
  WKWebView + an NSFilePresenter at once). This blanks the editor a different
  way (buffer never receives `doc.text`).
- The **external-reload path also failed** for the same file:
  `external reload skipped … (unreadable or not UTF-8)` — even though the file
  is valid UTF-8 (verified with `iconv`), consistent with the fd/coordination
  pressure, not a real encoding problem.
- A **restored** `Welcome.md` tab (seeded during scene restore, not a fresh
  open) DID render correctly earlier in the session (scratch `g1.png`), proving
  the view-install path can work on at least one code path.

Not yet isolated to a single line (the runtime degraded — multi-window churn
plus an accidental quit — before a clean lldb read of the frontmost window's
container was possible).

## Root cause (analysis)

Two mechanisms, both tracing back to the **multi-window / ghost-scene
pathology** that was explicitly deferred during the audit and has now escalated
from a cosmetic strip issue to breaking file-opening:

1. **Wrong-window routing (most likely dominant).** The app spawns several
   windows on launch; the opened file's editor surface is seeded into one
   container while the window in focus is a different, empty one. The chip can
   appear in the focused window's strip (identity-bound) while its content lives
   elsewhere.
2. **View not installed over the placeholder.** `EditorContainerViewController.activate(_:)`
   ([mac/Chalk/Editor/EditorContainerViewController.swift:474](../../mac/Chalk/Editor/EditorContainerViewController.swift#L474))
   early-returns on `guard activeTab !== tab` (:475). If `activeTab` is already
   the target but its surface view was removed from the hierarchy, no editor
   view is re-installed and the placeholder stays visible.

Secondary, real, and independent: **fd exhaustion** (`EMFILE`) during the
multi-window storm makes `UIDocument.open` fail outright. Related audit note:
"unbounded per-session security scopes" (report finding F6c).

### Design fragility that turns all of the above into a blank screen

The "No document open" empty state
([EditorContainerViewController.swift:586-608](../../mac/Chalk/Editor/EditorContainerViewController.swift#L586-L608),
`addEmptyState`) is a **permanent centered subview** of `contentView`. It is
never removed or hidden — it is only visually *covered* when an editor view is
added on top. So any path where a tab exists but its surface view is not the top
subview shows exactly this blank state. This should be an explicit
show/hide driven by "is an editor surface currently installed", not an
occlusion accident.

## Why no fix was applied yet

The dominant driver is the scene-restore / window-spawn lifecycle, which is a
design-level fix (UISceneSession restoration, how many windows connect), not a
one-liner — and blind patches at this exact UIKit↔AppKit seam have repeatedly
traded one failure for another this week (see the tab-strip pairing history).
The two candidate mechanisms above could not be cleanly disambiguated in the
corrupted runtime.

## Proposed plan (next session)

1. Rebuild with targeted diagnostic logging at two boundaries: `scene(_:willConnectTo:)`
   (how many scenes connect, what `initialContent` each gets) and
   `EditorContainerViewController.activate(_:)` / the view-install path (tab id,
   `activeTab`, whether `surface.view.superview` is nil).
2. Get ONE clean reproduction that pins mechanism (1) vs (2).
3. Make window spawning deterministic: one scene → one window on a cold launch;
   stop reconnecting stale/ghost scene sessions. This is also the root of the
   tab-strip trouble and the "restore drops/duplicates windows" anomalies.
4. Harden the empty state: show/hide it explicitly from "is an editor surface
   installed for `activeTab`", so a routing hiccup can never present a blank
   body with a live chip.
5. Bound file descriptors / security scopes so the multi-window path cannot hit
   `EMFILE` (addresses the secondary `doc.open` failure).
6. Add a regression test: open a file → assert `activeTab != nil` AND its
   surface view has a superview AND the empty-state is hidden.

## Reproduction

1. Quit Chalk; purge `~/Library/Containers/com.huleux.chalk/Data/Library/Saved Application State/*`.
2. Launch `/Applications/Chalk.app`.
3. Observe: multiple windows spawn; the window holding a tab shows "No document open".
4. Open any file (sidebar click, or `open -a Chalk <file>`): chip appears, body stays blank.

## Debugging side effects to be aware of

While investigating on 2026-07-24 the following were done to the local machine
(none touched user documents):

- Purged Chalk's Saved Application State (to force clean launches).
- Reset Chalk's Desktop/Documents TCC grants (`tccutil reset`).
- Re-signed `/Applications/Chalk.app` ad-hoc with the sandbox entitlements.

## Related

- Deferred pre-release audit item: ghost-scene restore race, restore
  dropping/duplicating windows (audit report §"still open").
- Tab-strip deterministic pairing (fixed): commits `7d81193`, `ed752ff`, plus
  the KVC/title-token pairing commit — same UIKit↔AppKit seam.

## Resolution (2026-07-26)

Root cause confirmed by static trace + on-disk forensics + live breadcrumbs.
There were TWO independent roots; both are closed.

**Root A (machine-local, the dominant one for the single-window blanks): the
2026-07-24 ad-hoc re-sign WITH the App Sandbox entitlement broke WKWebView.**
Under ad-hoc + `com.apple.security.app-sandbox`, the web content process never
runs the page: no JS, no paint, no `ready`, no error, no crash callback — the
editor waits forever on `seed gate: ready=false loaded=true`. Content rendered
earlier that same day (g1.png) because that was BEFORE the re-sign added the
entitlement ("Debugging side effects" above). Verified both ways on 2026-07-26:
the same build renders nothing when signed with the entitlement and seeds
within ~350 ms when signed without it; the built web bundle itself is clean in
a pristine WebKit (Playwright). Local deploys must ad-hoc sign WITHOUT the
sandbox entitlement; App Store builds get a real team signature, where the
sandbox works normally.

**Root B (architectural): the ghost-scene / view-install chain below.**

1. **Ghost scene sessions accumulated by design.** `captureRestorationActivity`
   returned a non-nil activity even for an empty window, nothing implemented
   `didDiscardSceneSessions`, and `configurationForConnecting` accepted every
   session — so empty windows persisted and reconnected forever, and an
   activity-less session fell back to a duplicate Welcome (tab + webview).
2. **The "clean launch" repro was never clean: Catalyst keeps TWO saved-state
   stores.** The purge in this doc's Reproduction section only hit the
   container store; `~/Library/Saved Application State/com.huleux.chalk~iosmac.savedState/`
   still held 4 sessions (2 real, 2 decoding to `{"tabs":[]}` ghosts). Which
   store is authoritative flips with the sandbox entitlement of each re-sign.
3. The window storm exhausted fds (eager per-tab `WKWebView` boot in
   `Tab.init`, per-tab `UIDocument`+`NSFilePresenter`, never-released
   `externalScopedURLs` scopes, watchdog double-boots) → `EMFILE` →
   `ChalkDocument.open` failed with only a log line.
4. The blank was structural: a transparent webview (`backgroundColor = .clear`)
   over a permanently installed "No document open" placeholder, plus
   `activate(_:)`'s identity-only guard and the reuse-browse branch doing no
   view work — so once blank, every subsequent sidebar click retitled the chip
   over a blank body. Mechanism 2 of the original analysis was right in shape;
   the transparency made mechanisms 1 and 2 visually indistinguishable.

Fix (all landed 2026-07-26, tests in `SceneLaunchPolicyTests` +
`EditorSurfaceInstallTests`):

- **Scene policy** (`ChalkKit.SceneLaunchPolicy` + `SceneDelegate`): only the
  first activity-less scene of a process opens Welcome, ghosts open empty; a
  one-shot launch-settle sweep (0.5 s) destroys surplus zero-tab scenes;
  `didDiscardSceneSessions` implemented for visibility.
- **View install invariant** (`EditorContainerViewController`):
  `ensureInstalled` repairs a detached surface on EVERY activation path
  including the reuse-browse branch; the empty state is explicitly
  shown/hidden from `activeTab`, never occluded.
- **Failure surfacing**: `documentController(_:didFailToOpen:)` presents a
  Retry / Close Tab alert instead of a silent blank.
- **fd bounds**: webview boot deferred to first show (`bootIfNeeded`; bulk
  session restore opens tabs with `activating: false` and boots exactly one);
  `externalScopedURLs` released on scene disconnect (after the flush lands).
- **Pairing hardening** (`ChalkAppKitGlue`): KVC lane requires exactly one
  `uiWindows` candidate; bind posts carry object AND token; the title-retry
  cushion arms unconditionally.

When purging saved state, purge **both** stores:

```sh
rm -rf ~/Library/Containers/com.huleux.chalk/Data/Library/"Saved Application State"/com.huleux.chalk~iosmac.savedState
rm -rf ~/Library/"Saved Application State"/com.huleux.chalk~iosmac.savedState
```
