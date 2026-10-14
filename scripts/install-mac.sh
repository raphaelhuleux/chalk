#!/usr/bin/env bash
#
# Rebuild Chalk for the Mac and replace ~/Applications/Chalk.app with it (the
# per-user Applications folder, so no admin rights are needed).
#
#   ./scripts/install-mac.sh               # Release, install, launch, verify
#   ./scripts/install-mac.sh --no-launch
#   ./scripts/install-mac.sh --config Debug
#   DEST=/Applications/Chalk.app ./scripts/install-mac.sh   # override the default ~/Applications/Chalk.app
#
# This is the local path, and it is ad-hoc signed: no Developer Program, no
# provisioning profile, nothing that expires. To hand a build to someone else
# use scripts/release-mac.sh instead: that one runs the full check suite,
# signs with a real identity and keeps the dSYMs.
#
# Three things here are not decoration. Each one has cost a day:
#   - never `codesign --deep` over an already-signed bundle
#   - never sign this with entitlements
#   - never ditto over a bundle that is still there
# The comments at each step say why.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
DEST="${DEST:-$HOME/Applications/Chalk.app}"
DD="${DD:-$ROOT/mac/build/dd}"        # shared with scripts/check.sh; gitignored
PREV=""                               # the rollback copy, named after DEST below
LAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) LAUNCH=0; shift ;;
    --config) CONFIG="${2:?--config needs Debug or Release}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PREV="$ROOT/mac/build/$(basename "$DEST").prev"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

case "$CONFIG" in
  Release) ;;
  Debug)
    cat <<'WARN'
warning: installing a Debug build over your daily app. It carries
         Chalk.debug.dylib, an unminified ~2 MB editor bundle and no
         optimisation, and its own settings (bundle ID com.huleux.chalk.debug).
         Correct for chasing a bug in the app itself, wrong for the copy
         you actually write in.
WARN
    ;;
  *) die "--config takes Debug or Release, not '$CONFIG'" ;;
esac

# --- 1. nothing can replace a bundle that is running ------------------------
step "Quitting Chalk"
# Anchored at DEST, not at any Chalk: a run with DEST pointing somewhere else
# has no business killing the copy you are working in.
DEST_RE="$(printf '%s' "$DEST" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
RUNNING="^$DEST_RE/Contents/MacOS/Chalk"
if pgrep -qf "$RUNNING"; then
  # `tell application id ... to quit` would LAUNCH it if it were not running,
  # which is why this is inside the pgrep guard.
  osascript -e 'tell application id "com.huleux.chalk" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -qf "$RUNNING" || break
    sleep 0.5
  done
  pgrep -qf "$RUNNING" \
    && die "Chalk is still running and would not quit. Quit it by hand (it may
       be holding an unsaved document) and re-run."
  echo "  quit."
else
  echo "  not running."
fi

# --- 2. build ---------------------------------------------------------------
# Chalk.xcodeproj is generated from mac/project.yml; XcodeGen only rewrites
# what changed, so this stays incremental-friendly.
step "xcodegen"
(cd "$ROOT/mac" && xcodegen generate --quiet)

# CODE_SIGNING_ALLOWED=NO is required, not a shortcut. The target uses
# Automatic signing with no team set, so a signed build dies with "requires a
# development team". Unsigned here, ad-hoc signed in step 4.
step "Building ($CONFIG, Mac Catalyst)"
echo "  a cold build is ~15 min; an incremental one is under a minute."
xcodebuild \
  -project "$ROOT/mac/Chalk.xcodeproj" \
  -scheme Chalk \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  CHALK_GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  -quiet \
  build

APP="$DD/Build/Products/$CONFIG-maccatalyst/Chalk.app"
[[ -d "$APP" ]] || die "the build reported success but there is no app at $APP"

# --- 3. audit the product ---------------------------------------------------
# Everything below is free and every item has been an actual shipped bug. The
# web bundle in particular is rebuilt by an Xcode pre-build phase, so "did the
# editor change reach the app?" is a real question with a checkable answer.
step "Auditing the build"
fail=0
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=1; fi; }

check "the AppKit glue is in Contents/PlugIns" \
      "[ -d '$APP/Contents/PlugIns/ChalkAppKitGlue.bundle' ]"
check "the editor bundle is present and non-trivial" \
      "[ \$(stat -f%z '$APP/Contents/Resources/editor/editor.html') -gt 200 ]"
if [[ "$CONFIG" == Release ]]; then
  # Minification is invisible in a diff and invisible at runtime, so it is
  # asserted by size, same ceiling as scripts/release-mac.sh.
  check "the web bundle is minified (js under 1.4 MB)" \
        "[ \$(stat -f%z '$APP/Contents/Resources/editor/bundle.js') -lt 1400000 ]"
  check "no test bundles shipped" \
        "! find '$APP' -name '*.xctest' | grep -q ."
  check "no debug dylibs" \
        "! find '$APP' -name '*.debug.dylib' -o -name '__preview.dylib' | grep -q ."
  check "the binary is universal" \
        "lipo -archs '$APP/Contents/MacOS/Chalk' | grep -q x86_64 && lipo -archs '$APP/Contents/MacOS/Chalk' | grep -q arm64"
fi
[[ "$fail" -eq 0 ]] || die "the build audit failed; not installing this."

# --- 4. sign, inside out ----------------------------------------------------
# NEVER `codesign --force --deep --sign -` here. A --deep pass over a bundle
# that is already signed corrupts the nested glue's seal ("code has no
# resources but signature indicates they must be present"), NSBundle then
# refuses to load it, and the app SILENTLY runs its UIKit tab fallback: no
# AppKit strip, wrong editor geometry, no error anywhere. Innermost first,
# plain --sign, then the app.
#
# NEVER pass --entitlements either. Ad-hoc + com.apple.security.app-sandbox
# kills the WKWebView content process, so the editor page never runs and never
# signals `ready`: a blank editor with nothing in any log. A real signature
# does not help (docs/issues/2026-08-19-sandbox-crash-loops-the-webview.md).
step "Signing (ad-hoc, inside out)"
# Every kind of nested code, not just the glue: a Debug build embeds
# ChalkTests.xctest here too, and one unsigned nested bundle fails the verify
# below with the same "code has no resources" line as a corrupted glue seal.
NESTED="$(find "$APP/Contents" -depth \( -name '*.bundle' -o -name '*.framework' \
          -o -name '*.appex' -o -name '*.xctest' -o -name '*.xpc' \) || true)"
while IFS= read -r nested; do
  [[ -n "$nested" ]] || continue
  echo "  ${nested#"$APP/"}"
  codesign --remove-signature "$nested" >/dev/null 2>&1 || true
  codesign --force --sign - "$nested"
done <<< "$NESTED"
codesign --force --sign - "$APP" 2>&1 | sed 's/^/  /'

step "Verifying the signature"
codesign --verify --deep --strict "$APP" \
  || die "the signature does not verify. Do not install this: the failure mode
       is silent (UIKit fallback, wrong chrome), not a crash."
echo "  valid, and --deep traverses the nested glue."
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q '<key>'; then
  die "this build carries entitlements. Ad-hoc + app-sandbox gives you a blank
       editor and no error. Sign it plain."
fi
echo "  no entitlements, which is what an ad-hoc build needs."

# --- 5. install -------------------------------------------------------------
# ditto MERGES into an existing bundle: stale files from the old app survive
# and a removed resource stays installed forever. The old bundle has to go
# first, so it is moved aside rather than deleted: that move is the rollback.
step "Installing to $DEST"
[[ -w "$(dirname "$DEST")" ]] || die "$(dirname "$DEST") is not writable by you."
ROLLED=0
if [[ -d "$DEST" ]]; then
  mkdir -p "$(dirname "$PREV")"
  rm -rf "$PREV"
  mv "$DEST" "$PREV"
  ROLLED=1
  echo "  previous build kept at $PREV"
fi
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST" || die "the installed copy does not verify."
echo "  installed and verified."

# --- 6. launch, and prove the glue actually loaded --------------------------
# Installing is not running, and running is not correct: the one failure this
# whole script is shaped around produces a perfectly launchable app with the
# wrong chrome. lsof answers it in one line.
if [[ $LAUNCH -eq 1 ]]; then
  step "Launching"
  open -a "$DEST"
  PID=""
  for _ in $(seq 1 20); do
    PID="$(pgrep -f "$(basename "$DEST")/Contents/MacOS/Chalk" | head -1 || true)"
    [[ -n "$PID" ]] && break
    sleep 0.5
  done
  [[ -n "$PID" ]] || die "the app did not stay running. Check Console.app for a
       crash report under Chalk."
  echo "  running, pid $PID"
  for _ in $(seq 1 10); do
    if lsof -p "$PID" 2>/dev/null | grep -qi 'ChalkAppKitGlue'; then
      echo "  AppKit glue loaded (real title-bar strip, not the UIKit fallback)."
      break
    fi
    sleep 0.5
  done
  lsof -p "$PID" 2>/dev/null | grep -qi 'ChalkAppKitGlue' || cat >&2 <<'WARN'
warning: the glue bundle is NOT loaded, so this app is running its UIKit tab
         fallback: no AppKit title-bar strip and the editor geometry is wrong.
         Check the glue's signature before you touch any layout code.
WARN
fi

step "Done"
COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :CHALKGitCommit' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "  $DEST  ($CONFIG, commit ${COMMIT:-?})"
[[ $ROLLED -eq 1 ]] && echo "  roll back with: rm -rf '$DEST' && ditto '$PREV' '$DEST'"
exit 0
