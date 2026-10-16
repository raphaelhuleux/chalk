---
name: install-mac
description: Use when asked to rebuild, reinstall, update, redeploy or "recompile" the Chalk Mac app on this machine (~/Applications/Chalk.app, the per-user folder), or to work out why the installed Mac build shows the wrong tab chrome, a blank editor, or stale editor behaviour.
---

# Installing Chalk on this Mac

## The command

```bash
cd <repo root> && ./scripts/install-mac.sh
```

That script ([scripts/install-mac.sh](../../../scripts/install-mac.sh)) is the whole
path: quit the running app, `xcodegen generate`, build unsigned, audit the
product, ad-hoc sign it inside out, verify, replace `~/Applications/Chalk.app`
and launch it.

Flags: `--no-launch`, `--config Debug`, `DEST=<path>`, `DD=<derived data>`.

A cold build is ~15 min, an incremental one under a minute. Derived data lives
at `mac/build/dd` (gitignored), shared with `scripts/check.sh`. The previous app
is moved to `mac/build/Chalk.app.prev`, and the script prints the one-line
rollback.

## This is not a release

[scripts/release-mac.sh](../../../scripts/release-mac.sh) is the other script and
they are not interchangeable. It gates on the full check suite, refuses a dirty
tree, signs with a real identity (optionally Developer ID and notarised) and
keeps the dSYMs. Use it for a build someone else will run. `install-mac.sh`
gates on nothing and signs ad-hoc: it is for the copy on this machine, and it
never expires.

## Release, not Debug

The default is Release because `~/Applications/Chalk.app` is the copy you write
in. A Debug build installed over it is a quiet downgrade: `Chalk.debug.dylib`,
an unminified ~2 MB editor bundle, no optimisation. `--config Debug` exists for
chasing a bug in the app itself and warns when you use it.

## Three failures here are silent, not loud

Each is a step in the script with a comment saying so. If you edit the script,
these are what the shape is protecting:

1. **`codesign --deep` over an already-signed bundle** corrupts a nested
   bundle's seal ("code has no resources but signature indicates they must be
   present") and NSBundle then refuses to load it. Sign innermost first with a
   plain `--force --sign -`, then the app, and sign *every* nested bundle: a
   Debug build embeds `ChalkTests.xctest` in `PlugIns`, and leaving it unsigned
   fails the verify with that line.
2. **Entitlements on an ad-hoc signature.** Ad-hoc plus
   `com.apple.security.app-sandbox` kills the WKWebView content process: the
   editor page never runs, never signals `ready`, and you get a blank editor with
   no error. Sign plain, no `--entitlements`. A real signature does not help:
   see [the sandbox note](../../../docs/issues/2026-08-19-sandbox-crash-loops-the-webview.md).
3. **`ditto` into an existing bundle merges.** Stale files survive and a removed
   resource stays installed forever. The old bundle is moved aside first.

Also: don't "fix" `CODE_SIGNING_ALLOWED=NO` by removing it. The target in
[mac/project.yml](../../../mac/project.yml) uses automatic signing with no team
set, so a signed build dies with "requires a development team". Local builds
are built unsigned and then ad-hoc signed by the script.

## Verifying

The script does it, but by hand: installing is not running, and running is not
correct.

```bash
codesign --verify --deep --strict ~/Applications/Chalk.app
```

A screenshot is the check for failure 2: the editor has to actually render
text.

## When an editor change does not show up

The web bundle is built by an Xcode pre-build phase, so `pnpm web:build`
alone never reaches the app. An editor-core change reaches
`~/Applications/Chalk.app` only through this script.
