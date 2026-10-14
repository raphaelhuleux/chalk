# A window sometimes comes up empty after switching windows (iPad)

Status: **open, instrumented 2026-08-18.** No fix applied: the root cause is not established, and the two candidate mechanisms have opposite fixes.

## Symptom

Owner report, iPad, 2026-08-18: "sometimes, when switching windows, the app appears empty (no text in the editor, side bar empty too)".
Reported switch path: the iPad app switcher, with an external monitor attached.
Whether the tab chips survive, and whether the window heals on its own, was not observed.

## Why it is not fixable from the report alone

Two mechanisms produce the same screenshot and need opposite fixes.

1. **Ghost scene.** A window with no tabs at all. `SceneLaunchPolicy.initialContent` opens EMPTY for every activity-less scene after the process's first one, and `SceneDelegate.sweepSurplusEmptyScenes` runs ONCE, 0.5s after the first connect. An empty scene that appears later in the process therefore survives and is switchable-to. What the user sees is the real "No document open" placeholder plus an empty tab strip (verified against the `empty` audit state), and the Library is simply closed, as it is on every fresh window. The fix would live in the scene lifecycle.
2. **Live window that failed to come back.** Tabs still in the model, but the active surface's view is not installed (the 2026-07-26 `ensureInstalled` invariant), or the webview's content process was jettisoned in the background and never re-seeded, or the Library panel was pushed out of its own column (the clamped `viewDidLayoutSubviews` compensation in `SidebarViewController`, which is the earlier "the panel reads as empty" report from 2026-08-17). The fix would live in the view-install / reload paths.

The external monitor is a live third possibility: `DeclinedSceneDelegate` (added the same day) destroys every session whose role is not `.windowApplication`, so a session iPadOS expected to keep would come back as nothing.

## Instrumentation now in the build

`SceneDelegate.logState` prints one line on connect, disconnect, foreground and activate, under subsystem `com.huleux.chalk`, category `scene`:

```
didBecomeActive session=<id> role=<role> activation=<state> scenes=N \
  tabs=N active=<file> surfaceInstalled=<bool> placeholder=<bool> \
  locations=N rows=N emptyLabel=<hidden|SHOWN> panel=x,y WxH \
  displayMode=… band=… safeTop=… size=…
```

Reading the fields when the blank window is on screen:

- `tabs=0` and `placeholder=true`: mechanism 1, a ghost scene. Check the `connect` line for that session: `ordinal=` and `restored=false` say it opened empty by policy.
- `tabs>0` with `surfaceInstalled=false` or `placeholder=true`: mechanism 2, the view-install path.
- `tabs>0`, `surfaceInstalled=true`, `placeholder=false`, and still blank: the webview never re-seeded. Cross-check the `editor` / `doc` categories.
- `rows=0` or `emptyLabel=SHOWN`: the Library really is empty (enumeration or Location resolution failed).
- `rows>0` with a `panel=` origin outside the column: the panel was pushed out, the 2026-08-17 shape again.
- A `declining scene session with role …` line right before the blank implicates the external-display gate.

## Capturing it

With the iPad connected to the Mac:

```sh
log stream --device --predicate 'subsystem == "com.huleux.chalk"' --info
```

Reproduce (app switcher, monitor attached), then read the last `didBecomeActive` line for the window that came up empty.

## Related

- `docs/issues/2026-07-24-blank-editor-on-open.md`: the earlier blank-editor P0, both roots closed. Its scene policy and view-install invariant are the code this report lands on top of.
- `SidebarPanelAlignmentTests`: the clamped compensation, with the "Library reads as empty" reasoning at the test.
