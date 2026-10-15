#!/usr/bin/env bash
#
# Retakes the README's Mac screenshots into docs/images/.
#
#   ./scripts/screenshots/capture-mac.sh              # build Debug, capture every shot
#   ./scripts/screenshots/capture-mac.sh --no-build   # reuse the last Debug build
#
# Drives the Debug app (bundle ID com.huleux.chalk.debug, so the installed app's
# settings are never touched) through the DEBUG-only `promo-file` audit state,
# opening the documents in docs/showcase/. Theme and view mode are launch
# arguments: they override the settings for that launch without saving them.
#
# It takes over the screen for about a minute: each window comes to the front,
# because WKWebView stops drawing in a window that is not on screen. Don't type
# or click while it runs; input lands in the shot. The terminal needs Screen
# Recording permission.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DD="$ROOT/mac/build/dd"
APP="$DD/Build/Products/Debug-maccatalyst/Chalk.app"
OUT="$ROOT/docs/images"
SHOW="$ROOT/docs/showcase"
WIDTH=1600 # README images are shown at most ~900px wide; 1600 keeps them sharp on retina

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

if [[ "${1:-}" != --no-build ]]; then
  (cd "$ROOT/mac" && xcodegen generate --quiet)
  xcodebuild build -project "$ROOT/mac/Chalk.xcodeproj" -scheme Chalk -configuration Debug \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -quiet
fi
[[ -d "$APP" ]] || die "no Debug build at $APP; run without --no-build"

TMP="$(mktemp -d)"
trap 'quit_app; rm -rf "$TMP"' EXIT
swiftc -O "$ROOT/scripts/screenshots/winid.swift" -o "$TMP/winid"

quit_app() {
  pkill -f "$APP/Contents/MacOS/Chalk" 2>/dev/null || true
  sleep 2
}

# shot NAME FILE [ENV=VALUE ...] -- [launch arguments]
shot() {
  local name="$1" file="$2"; shift 2
  local envs=(--env CHALK_AUDIT_STATE=promo-file --env "CHALK_AUDIT_FILE=$file")
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=(--env "$1"); shift; done
  [[ "${1:-}" == -- ]] && shift
  local pid="" win="" attempt
  # Two attempts: a launch issued while the previous instance is still quitting
  # can be dropped by LaunchServices without an error.
  for attempt in 1 2; do
    quit_app
    open -n -a "$APP" "${envs[@]}" --args \
      -chalk.themePreference 2 -chalk.colorTheme atom "$@"
    for _ in $(seq 20); do
      sleep 1
      pid="$(pgrep -f "$APP/Contents/MacOS/Chalk" | head -1 || true)"
      [[ -n "$pid" ]] && win="$("$TMP/winid" "$pid" 2>/dev/null | cut -d' ' -f1 || true)"
      [[ -n "$win" ]] && break 2
    done
  done
  [[ -n "$win" ]] || die "$name: the app never showed a window"
  osascript -e 'tell application id "com.huleux.chalk.debug" to activate' >/dev/null 2>&1 || true
  sleep 4 # web view boot, KaTeX, the outline panel's delayed open
  # The window may have resized since it first appeared; look it up again.
  local again
  again="$("$TMP/winid" "$pid" 2>/dev/null | cut -d' ' -f1 || true)"
  [[ -n "$again" ]] && win="$again"
  screencapture -x -o -l "$win" "$TMP/$name.png"
  sips --resampleWidth "$WIDTH" "$TMP/$name.png" --out "$OUT/$name.png" >/dev/null
  echo "  $name.png"
}

mkdir -p "$OUT"
echo "capturing into ${OUT#$ROOT/}"
shot mac-hero   "$SHOW/least-squares.md"  CHALK_AUDIT_LIBRARY="$SHOW" CHALK_AUDIT_SIZE=1280x900 CHALK_AUDIT_LINE=2
shot mac-mixed  "$SHOW/least-squares.md"  CHALK_AUDIT_SIZE=1100x900 CHALK_AUDIT_LINE=2 -- -chalk.viewMode mixed
shot mac-tex    "$SHOW/least-squares.tex" CHALK_AUDIT_OUTLINE=1 CHALK_AUDIT_SIZE=1280x900 CHALK_AUDIT_LINE=3
shot mac-beamer "$SHOW/slides.tex"        CHALK_AUDIT_SIZE=1100x900
