# Mac: the window leaves full screen around the outline palette (⌘;)

Status: **FIXED 2026-08-17** (same day), verified live in full screen against a
real keyDown of the owner's exact keycode; owner confirmation on the physical
keyboard still welcome. Root cause and fix below; the failed-attempts history
is kept because attempt 2's analysis shaped the fix.

## Root cause (solved)

The drop was never spontaneous and never a race. A `willExitFullScreen`
observer registered with `queue: nil` (so it runs on the poster's stack)
captured the initiator:

```
sendEvent → -[UINSInputView doCommandBySelector:] →
_NSExitFullScreenTransitionController … startTransition
currentEvent: keyDown keyCode=43 chars=";"
```

The chain: with the outline palette's **native UITextField focused**, a ⌘;
keyDown is handed by Catalyst to `NSTextInputContext` BEFORE any UIKit
mechanism — UIKeyCommands (`wantsPriorityOverSystemBehavior` included) and
`pressesBegan` never see it (which is why the original diagnostic saw "no
second press": the instrumentation was UIKit-side, the consumption AppKit-side).
On keyboard layouts where "." shares the ";" key — French AZERTY, keyCode 43 —
the input context reads ⌘; as the cancel key **⌘.** and forwards
`cancelOperation:`-style handling to `NSWindow`'s default, which in full
screen is **exit full screen**. The app's own menu equivalent (`Outline ⌘;`)
never matched the press on AZERTY (AppKit localizes key equivalents), so
nothing stood between the keystroke and the cancel alias.

That explains both halves of the report exactly: the second ⌘; ends full
screen AND never reaches `cmdToggleOutline` (the palette stays open). It also
explains why Quick Open was immune ("o" shares no key with ".") and why the
"1.1s after open" looked like a race — it was just the human interval between
the first and second press. This only reproduces with a native text field
focused; with the webview focused, the webview swallows the key and the JS
forward lane delivers it (the first press, which opened the palette).

## The fix (two lanes + instrumentation, all in-tree)

1. **`ChalkAppKitGlue`: a local `NSEvent` monitor** (`addLocalMonitorForEvents`,
   `.keyDown`) that matches plain-⌘ ";" **by character** (layout-independent),
   only for windows the glue owns a toolbar controller for, swallows the event
   (returning nil), and posts `chalk.shell.key` with the window number. This
   runs before `sendEvent` dispatch, i.e. before the menu, the text-input
   funnel, and the webview alike. `RootSplitViewController.handleGlueShellKey`
   routes it to `cmdToggleOutline` on the bound scene.
2. **`RootSplitViewController.keyCommands`: scene-level ⌘; UIKeyCommand**
   (priority flag) — the iPad-hardware-keyboard and H-6 no-glue lane. Verified
   limit: it cannot beat the text-input funnel while a native field is editing;
   on Mac-with-glue the monitor swallows the key first, so this lane is simply
   never consulted there. It lives on the ROOT, not the palette VCs — see
   attempt 2's lesson below. Tests: `ChalkTests/ShellOutlineKeyCommandTests`
   (command shape + the palettes-must-not-shadow regression guard).
3. **Permanent breadcrumbs** (info-level, `com.huleux.chalk`): `outline`
   category (toggle/present/hide/fetch/grabFocus) in the app; `glue` category
   gained `willExitFullScreen` + initiator stack + `NSApp.currentEvent`, and
   `keyMonitor` claims. This bug was timing-dependent; the trail stays on.

Verified end-to-end on the deployed build: full screen → palette open → field
focused (`grabFocus: won=true`) → CGEvent keyDown keycode 43 + ⌘ (the exact
event from the live capture) → `keyMonitor` claim → `cmdToggleOutline
visible=true` → palette closed, **no** `willExitFullScreen`. Repeated
close/open/close cycles stayed in full screen throughout.

## Symptom (owner's words)

> if the app is in full screen and I press cmd + ; twice, it switches to
> windowed mode

Refined a few minutes later:

> if the outline pane is activated, and the app in full screen, pressing cmd + ;
> again put it in windowed mode, and **does not desactivate the outline pane**

The second half matters: the palette staying open means `cmdToggleOutline` did
not run, so the app never saw that press.

## What the instrumented run actually showed

A temporary diagnostic build (breadcrumbs in `cmdToggleOutline`,
`hideOutlinePalette`, `handleWindowFullScreenChange`, plus a `pressesBegan`
override on `OutlinePaletteViewController` logging every key and modifier) was
deployed and the owner reproduced by hand. Full capture:

```
17:13:31.152 glue    styleAllWindows: window 107208 primary=true hasController=false
17:13:31.156 glue    postBind: window 107208 object=false token=true key=true
17:13:31.157 glue    postBind: window 107208 object=false token=true key=true
17:13:32.527 glue    fullScreenChange: window 107208 on=true
17:13:32.527 outline handleWindowFullScreenChange -> true
17:13:32.727 outline cmdToggleOutline entered: outlineVisible=false macFullscreen=true
17:13:33.815 glue    fullScreenChange: window 107208 on=false      ← THE BUG
17:13:33.815 outline handleWindowFullScreenChange -> false
17:13:34.029 outline palette pressesBegan: chars= cmd=true shift=false ctrl=true alt=true raw=1835008
17:13:35.183 glue    fullScreenChange: window 107208 on=true
             (no further exit — stable from here on, palette still open)
```

Read it carefully, because it contradicts the report's framing:

1. **No second ⌘; preceded the drop.** There is exactly one
   `cmdToggleOutline` (the press that OPENED the palette) and no character
   keypress at all before `on=false`. The only key event in the whole capture is
   a modifiers-only press (⌘⌃⌥, `raw=1835008`, no character) that lands
   *after* the drop — almost certainly the owner re-entering full screen.
2. **The drop is 1.1s after the palette opened**, and the palette opened only
   200ms after the full-screen transition completed.
3. **Full screen is stable with the outline open.** After re-entering at
   35.183 it never dropped again, and `hideOutlinePalette` never logged — the
   palette was open the entire time.
4. **The app logged nothing between 32.727 and 33.815.** No `styleAllWindows`,
   no shell command, nothing. Whatever ended full screen was not an app-side
   call that this instrumentation covers.

**The report and the log disagree about the trigger, and reconciling them is
step 1.** Either the drop needs the transition to be recent (a race), or the
owner's manual sequence differed from what the timestamps suggest.

## What is ruled out (each with evidence, not reasoning)

- **The overlay/palette machinery.** ⌘O (Quick Open) drives the identical path
  — hide the other palette, unhide backdrop, `editor.blurActiveSurface()`,
  `revealPaletteOverlay`, `didReveal()`, `grabFocus` retries, focus return on
  close. Tested in full screen on the deployed build: entered 16:09:31.554,
  **no exit followed**. So the shared overlay code is innocent.
- **The glue's `didBecomeKey` restyle.** `ChalkAppKitGlue` re-runs
  `styleAllWindows()` + `installBand` + `postBind` on every
  `NSWindow.didBecomeKeyNotification`. No `styleAllWindows` line appears between
  the palette opening and the drop, so no key round trip occurred there.
- **The palette height callback.** `onContentHeightChanged` is byte-identical
  for both palettes ([RootSplitViewController.swift:1884](../../mac/Chalk/App/RootSplitViewController.swift#L1884)
  vs [:2088](../../mac/Chalk/App/RootSplitViewController.swift#L2088)) and only
  sets a constraint constant. No window geometry.
- **App-side geometry requests.** The only `requestGeometryUpdate` in the app
  is inside `#if DEBUG` for the `narrow` audit state
  ([RootSplitViewController.swift:2320](../../mac/Chalk/App/RootSplitViewController.swift#L2320)).
  `sizeRestrictions` is set once per scene at connect.

## Failed attempts — do not repeat these

**1. Skip the AppKit titlebar band in full screen** (`ChalkTabStrip.installBand`
guarded on `styleMask.contains(.fullScreen)`, exit path forced) **plus
conditional titlebar writes** in `ChalkAppKitGlue.styleAllWindows` (only assign
`titlebarAppearsTransparent` / `backgroundColor` when actually changed).

Rationale: the glue re-asserts window chrome on every key change, and doing that
to a window macOS is animating could knock it out of full screen. Result: **no
change** — the drop still happened. Reverted. (The reasoning may still be sound
as hygiene, but it is not this bug.)

**2. Make the palettes claim their own toggle keys.** Added
`UIKeyCommand(input: ";", modifierFlags: .command)` with
`wantsPriorityOverSystemBehavior = true` to `OutlinePaletteViewController`, and
⌘O/⌘P equivalents to `QuickOpenViewController`.

Rationale (still believed correct as an analysis, wrong as a fix here): once a
palette holds the responder chain, two of the shell's three delivery lanes are
gone, because `EditorWebView.pressesBegan` and the `native-host.ts` keydown forward
both live on the editor web view. macOS owns ⌘; ("Check Document Now" — the
collision `AppDelegate.buildMenu` already removes the `.spelling` menu for).

Result: **REGRESSION.** ⌘; stopped opening the outline entirely. Both palettes
are **mounted once as permanent child view controllers** and are therefore
*always* in the responder chain — see the comments at
[RootSplitViewController.swift:1821](../../mac/Chalk/App/RootSplitViewController.swift#L1821)
and [:2034](../../mac/Chalk/App/RootSplitViewController.swift#L2034). Their
`keyCommands` are live whenever the app runs, not only while the palette shows,
so the new command permanently shadowed `cmdToggleOutline`, and
`wantsPriorityOverSystemBehavior` guaranteed it won. Reverted.

**Lesson for the next attempt: any `keyCommands` change on either palette VC
applies at all times.** Gate on visibility if you go there again.

## Hypotheses (historical — all four resolved by the fix above)

Hypothesis 4 (identify the initiator) was the one that cracked it, via the
`queue: nil` stack capture. 1–3 were red herrings born of the timing artifact.

1. **Race with the full-screen transition.** The palette opened 200ms after
   `didEnterFullScreen` and the drop came 1.1s later; after a settled
   re-entry it never recurred. Test with pauses: full screen → wait 10s →
   ⌘; → wait 5s → ⌘;. If it never drops, defer `presentOutlinePalette` until
   the transition settles (or ignore an open request while one is in flight).
2. **The async outline fetch.** `editor.fetchActiveOutline` →
   `WebEditorSurface.fetchOutline` → `evaluateJavaScript` is the *only* thing
   the outline does that Quick Open does not, and its completion lands in the
   right time window. Test by stubbing the fetch to deliver `.empty`
   synchronously and re-running the repro.
3. **The focus-grab retry loop.** `grabFocus(retries: 5)` re-tries
   `searchField.becomeFirstResponder()` every 60ms
   ([OutlinePaletteViewController.swift:382](../../mac/Chalk/Features/OutlinePaletteViewController.swift#L382)).
   Quick Open has the same shape but a shorter settle. Test by opening the
   outline with the grab disabled.
4. **Confirm who ends full screen.** Observe
   `NSWindow.willExitFullScreenNotification` in the glue and log a stack
   symbolication / `NSApp.currentEvent` at that moment. If nothing in-process
   asks, it is macOS, and the fix belongs in what the app does *during* the
   transition.

## How to reproduce and instrument

**Build + deploy** (no Developer team; see also
`docs/issues/2026-07-24-blank-editor-on-open.md` for why the sandbox entitlement
must NOT be added):

```sh
cd mac && xcodebuild -project Chalk.xcodeproj -scheme Chalk -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build-claude CODE_SIGNING_ALLOWED=NO build
cd .build-claude/Build/Products/Debug-maccatalyst
# sign INSIDE-OUT; never --deep over an already-signed app (corrupts the glue seal)
codesign --remove-signature Chalk.app/Contents/Resources/ChalkAppKitGlue.bundle
codesign --force --sign - Chalk.app/Contents/Resources/ChalkAppKitGlue.bundle
codesign --force --sign - Chalk.app
codesign --verify --deep --strict Chalk.app
rm -rf /Applications/Chalk.app && ditto Chalk.app /Applications/Chalk.app
# VERIFY the deploy by hash, not by timestamp:
shasum Chalk.app/Contents/MacOS/Chalk /Applications/Chalk.app/Contents/MacOS/Chalk
```

**Watch the transitions** (note `/usr/bin/log` — `log` is shadowed in this
user's zsh, and `--info` is required or nothing appears):

```sh
/usr/bin/log stream --predicate 'subsystem == "com.huleux.chalk"' --info --style compact
```

`fullScreenChange: window N on=true|false` comes from
`ChalkAppKitGlue.postFullScreenChange`, which is driven by AppKit's own
`didEnter/didExitFullScreenNotification` — it is ground truth for this bug.

**Synthetic input, what actually works (2026-08-17).** `osascript … keystroke`
remains unreliable (AZERTY: `keystroke ";"` maps through US keycodes and can
land as ⌘M/minimize; System Events sees 0 windows for a full-screen Catalyst
process; strays hit other apps). What worked instead:

- **Repro without any keystroke**: `open -a /Applications/Chalk.app --env
  CHALK_AUDIT_STATE=fsoutline` — a DEBUG audit state that opens a heavy doc,
  enters full screen through the glue's `chalk.debug.toggleFullScreen` hook
  (real `toggleFullScreen`, no keys), and toggles the outline
  `CHALK_AUDIT_FS_DELAY` seconds (default 0.25) after `didEnterFullScreen`.
  Launch via `open --env`, NEVER the bare binary — a later
  `tell app "Chalk" to activate` against a direct-binary instance spawns a
  second copy (the multi-instance trap, hit again during this fix).
- **The keystroke itself**: a tiny Swift script posting `CGEvent`
  `virtualKey: 43` + ⌘ (the exact physical key from the capture), guarded by
  an `NSWorkspace.frontmostApplication == "Chalk"` abort so a stray can never
  land elsewhere. Character-based APIs are the trap; keycode + frontmost-guard
  is the reliable lane.

## Related

- Commit `b00cd7e` "heal the titlebar band across full-screen transitions" —
  the most recent deliberate work in this area; attempt 1 above modified it and
  was reverted.
