# The App Sandbox crash-loops WKWebView's content process

**Status:** cause found 2026-10-15 (see "Resolution" below). Blocks the Mac App Store, not the alpha; the fix is a product decision, not code.
**Answers:** Phase 0 of `docs/plans/2026-08-19-mac-alpha-and-waitlist.md` (removed 2026-09-28; in git history).

## What happens

A sandboxed Mac Catalyst build launches, draws its whole chrome, loads the
document, and shows an empty editor forever. The tab is live and untitled.

The single line that names it, from `log stream --predicate 'subsystem ==
"com.huleux.chalk"' --info`:

    [doc] seed gate: ready=false loaded=true seeded=false

and then nothing. That line is not itself a fault: it appears in a healthy
launch too, and resolves 216 ms later with `ready received; flushing 1 pending
message(s)`. Sandboxed, the `ready` never arrives.

## The mechanism

WKWebView's WebContent XPC service spawns and immediately exits, in a loop.
From `log show --predicate 'process == "launchd"'`, filtered to the app's pid:

    Successfully spawned WebContent[65950] because ipc (mach)
    service inactive: com.apple.WebKit.WebContent.57667AE6-...
    Successfully spawned WebContent[65952] because ipc (mach)
    service inactive: com.apple.WebKit.WebContent.A1552120-...
    ...

Counted over the same 25-second window:

| | WebContent spawns |
| --- | --- |
| Sandboxed | **776** |
| Unsandboxed | **1** |

No `Sandbox: ... deny` line names Chalk. The denials in the log during these
runs belong to `imagent` and `searchpartyuseragent` and are unrelated.

## What was ruled out

**It is not the ad-hoc signature.** This was the standing hypothesis since
2026-07-24, recorded as "ad-hoc + sandbox silently kills WKWebView", and it is
wrong. The build here is signed by `Apple Development: ... (<CERT_ID>)`,
chained to the Apple Root CA, carrying `TeamIdentifier=<TEAM_ID>` and a real
provisioning profile.

**It is not the editor bundle.** `Contents/Resources/editor/` contains real
files (`bundle.js`, `bundle.css`, `editor.html`), not a symlink, and
`loadFileURL(html, allowingReadAccessTo: dir)` points inside the app bundle.

**It is not any other build difference.** The controlled experiment holds
everything constant: one Release build, copied, and the copy re-signed with the
same identity and an entitlements file containing only
`com.apple.security.get-task-allow`. Sandboxed copy: blank. Unsandboxed copy:
renders a Quarto document with numbered equations and cross-references.

Removing exactly one entitlement is the whole difference.

## What was not tried, and why

Adding `com.apple.security.network.client`. It is the usual first suggestion for
WebContent trouble in a sandboxed app, and it may well fix this. It is also the
one entitlement Chalk must not have: "this app makes no network connections" is
the first line of the Privacy screen and of the waitlist page, and an
entitlement that contradicts it costs more than the App Store is worth right
now. If it turns out to be the fix, the honest move is to say so on both
surfaces rather than to hold the claim and the entitlement at once.

Worth trying before that, when this is picked up:

- `com.apple.security.temporary-exception.mach-lookup.global-name` for the
  WebKit services, which is the narrower version of the same idea.
- Whether the iPad idiom is implicated: this is Catalyst running the iPad idiom,
  and WebContent's sandbox profile may differ from the AppKit idiom's.
- A minimal sandboxed Catalyst app with one WKWebView and one local file, to
  establish whether this is Chalk at all or the configuration.

## What it changes

**Nothing for the alpha.** Direct-download Mac apps are routinely unsandboxed;
the sandbox is an App Store requirement, and the alpha is not going to the App
Store. `Chalk-macCatalyst.entitlements` stays as it is (the file is correct, it
simply cannot be applied yet), and alpha builds ship without it.

**It blocks the Mac App Store**, which is a Phase 7 problem and now a known one
rather than an unknown.

**Two claims are now untested rather than false.** Security-scoped bookmarks and
the conflict copy-aside fallback both have branches that only run under a real
sandbox. They cannot be exercised until this is solved, and
`docs/plans/2026-08-19-mac-alpha-and-waitlist.md` (removed 2026-09-28; in git history) lists both under Verification.

## Reproducing

    git worktree add --detach /tmp/wt HEAD
    ln -s "$PWD/mac/Chalk/Resources/editor" /tmp/wt/mac/Chalk/Resources/editor
    cd /tmp/wt/mac && xcodegen generate && cd /tmp/wt
    xcodebuild build -project mac/Chalk.xcodeproj -scheme Chalk \
      -destination 'platform=macOS,variant=Mac Catalyst' -configuration Release \
      -derivedDataPath /tmp/dd CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates

Purge both saved-state stores first, `~/Library/Containers/com.huleux.chalk/
Data/Library/Saved Application State/` and `~/Library/Saved Application State/`,
because which one wins flips with the sandbox entitlement.

## Resolution (2026-10-15)

Reproduced on the AppKit shell (`ChalkMac`, plan phase 1) with the same
symptom, so it is not Catalyst and not the iPad idiom. A minimal AppKit app
with one `WKWebView` loading one bundled HTML file, signed with the same
development identity, settles it on macOS 27.0:

| Entitlements | Result |
| --- | --- |
| none | renders |
| `app-sandbox` only | `webViewWebContentProcessDidTerminate` fires once, nothing renders |
| `app-sandbox` + `network.client` | renders |

WKWebView's content process does not survive the App Sandbox without
`com.apple.security.network.client`, even for `file://` content. That is the
one entitlement the Privacy screen's "no network connections" claim rules out,
so the sandboxed App Store build stays blocked until the owner decides between
the claim and the entitlement. Nothing in Chalk's code is involved; local and
direct-download builds keep shipping unsandboxed. Probe source: scratch, not
kept; it is twenty lines of `WKWebView.loadFileURL` plus a status file.
