# AZERTY `^^` gives `^{^t}`

Status: **fixed, 2026-11-06.**

## Symptom

On ABC-AZERTY, typing `^` `^` `t` in math gave `^{^t}` instead of `^{t}`.

## Evidence

On ABC-AZERTY, `^` is a dead key. A Safari trace on the owner's Mac (Safari runs the same WebKit text input as the app's WKWebView), keys `^` `^` `t` after `x`:

```
^   compositionstart; insertCompositionText "^"                      x^   (pending)
^   deleteCompositionText; insertFromComposition "^"; compositionend  x^
    compositionstart; insertCompositionText "^"                      x^^  (a NEW pending ^)
t   deleteCompositionText; insertFromComposition "^"; compositionend  x^^
    insertText "t"                                                   x^^t
```

The second `^` commits the first and opens a new composition, so the second `^` stays pending until the next key.
AppKit WebKit does not repeat the commit on the next key (no `insertText "^t"`), unlike the Catalyst shape `dead-key-commit.ts` handles.

## Cause

CM6 reads composed text into the document as it is marked, so the doc was `x^^` while the second `^` was still pending.
hsnips' auto-expansion fired on that single-character insert and rewrote the line to `x^{}`.
WebKit still owned the pending `^`, and on `t` it committed it at the caret, now inside the braces.

## Fix

`autoExpandFor` (hsnips-plugin.ts) does not expand while `view.compositionStarted`; it marks the view and checks once in a microtask after `compositionend`, before the key that ended the composition types its own character.
`^` `^` now shows `^^` with the second one pending, and expands on the next key: `t` gives `^{t}`, space gives `^{}`.

Regression: `Tests/browser/run.mjs` scenario "azerty dead ^ ^ expands ^^ once" replays the trace in md and tex, inline and display math, ending with `t` or space; all 16 checks fail on the old code in WebKit.
