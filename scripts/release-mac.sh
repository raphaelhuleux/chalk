#!/usr/bin/env bash
#
# Build a signed Mac release of Chalk for direct download: the Mac Catalyst
# shell by default, the AppKit shell (ChalkMac) with --appkit, until cutover
# makes the AppKit shell the only one.
#
#   CHALK_SIGN_IDENTITY="Chalk Self-Signed" ./scripts/release-mac.sh
#   CHALK_SIGN_IDENTITY="Chalk Self-Signed" ./scripts/release-mac.sh --appkit
#
# Maintainer path, notarised for Gatekeeper (needs a paid Apple Developer
# account, a "Developer ID Application" certificate in the keychain and a
# notarytool keychain profile):
#
#   CHALK_SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)" \
#   CHALK_TEAM_ID=<TEAM_ID> \
#   CHALK_NOTARY_PROFILE=<profile> \
#   ./scripts/release-mac.sh
#
# Produces, under dist/<version>-<build>/:
#   Chalk.app             the signed app
#   Chalk-<version>.zip   what you send
#   Chalk.xcarchive       KEEP THIS. Its dSYMs are the only way to symbolicate
#                         a crash from a build already on someone's machine.
#   manifest.txt          what this build is, in one file
#
# Nothing here touches scripts/check.sh: a release script that could relax
# its own gate is not a gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

SHELL_KIND=catalyst
for arg in "$@"; do
  case "$arg" in
    --appkit) SHELL_KIND=appkit ;;
    *) die "unknown argument: $arg" ;;
  esac
done
case "$SHELL_KIND" in
  catalyst)
    SCHEME=Chalk
    DESTINATION='generic/platform=macOS,variant=Mac Catalyst'
    PRODUCT=Chalk.app
    BINARY=Chalk
    HAS_GLUE=1
    ;;
  appkit)
    SCHEME=ChalkMac
    DESTINATION='generic/platform=macOS'
    PRODUCT=ChalkMac.app
    BINARY=ChalkMac
    HAS_GLUE=0
    ;;
esac

# --- 1. Refuse to build something nobody can reproduce ----------------------
step "Checking the working tree"
[ -z "$(git status --porcelain)" ] \
  || die "the working tree is dirty. A build you cannot reproduce from a commit
       is a build you cannot debug a report against."

COMMIT="$(git rev-parse --short HEAD)"
BUILD="$(git rev-list --count HEAD)"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' mac/project.yml | head -1)"
[ -n "$VERSION" ] || die "could not read MARKETING_VERSION from mac/project.yml"
BUILD_DATE="$(date -u +%Y-%m-%d)"

echo "version $VERSION  build $BUILD  commit $COMMIT"

OUT_TMP="$ROOT/dist/$VERSION-$BUILD"

# --- 2. Signing identity ----------------------------------------------------
step "Checking the signing identity"
IDENTITY="${CHALK_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || die "set CHALK_SIGN_IDENTITY. Without a paid Apple Developer
       account, create a self-signed one in Keychain Access (Certificate
       Assistant > Create a Certificate, type 'Code Signing')."
security find-identity -v -p codesigning | grep -q "$IDENTITY" \
  || die "no code-signing identity matching '$IDENTITY' in the keychain."

TEAM="${CHALK_TEAM_ID:-}"
NOTARY="${CHALK_NOTARY_PROFILE:-}"
case "$IDENTITY" in
  "Developer ID Application"*)
    [ -n "$TEAM" ] || die "a Developer ID identity needs CHALK_TEAM_ID (the team that owns it)."
    EXPORT_METHOD=developer-id
    ;;
  *)
    [ -z "$NOTARY" ] || die "CHALK_NOTARY_PROFILE needs a Developer ID Application identity."
    EXPORT_METHOD=mac-application
    ;;
esac
# Notarisation rejects a build without the hardened runtime, so it is turned
# on exactly when the build will be notarised.
HARDENED=NO
[ -z "$NOTARY" ] || HARDENED=YES

# --- 3. The gate ------------------------------------------------------------
step "Running the full check suite"
# The gate is "check.sh exits 0"; any failure stops the release.
CHECK_LOG="$OUT_TMP/check.log"
mkdir -p "$(dirname "$CHECK_LOG")"
if ! ./scripts/check.sh > "$CHECK_LOG" 2>&1; then
  grep '^  case: ' "$CHECK_LOG" | sed 's/^  case: */    /' | sort -u || true
  tail -5 "$CHECK_LOG"
  die "check.sh failed.
       Full log: $CHECK_LOG
       Do not ship past this. See docs/known-failing-tests.md."
fi
echo "  check.sh is fully green."

# --- 4. Build ---------------------------------------------------------------
step "Generating the Xcode project"
(cd mac && xcodegen generate)

OUT="$OUT_TMP"
mkdir -p "$OUT"
ARCHIVE="$OUT/Chalk.xcarchive"

step "Archiving"
# CODE_SIGN_ENTITLEMENTS is blanked: the App Sandbox entitlement that
# mac/project.yml applies leaves the editor blank
# (docs/issues/2026-08-19-sandbox-crash-loops-the-webview.md).
xcodebuild archive \
  -project mac/Chalk.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  ${TEAM:+DEVELOPMENT_TEAM="$TEAM"} \
  ENABLE_HARDENED_RUNTIME="$HARDENED" \
  CODE_SIGN_ENTITLEMENTS= \
  CHALK_GIT_COMMIT="$COMMIT" \
  CURRENT_PROJECT_VERSION="$BUILD"

step "Exporting"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$EXPORT_METHOD</string>
  <key>signingStyle</key><string>manual</string>
$( [ -z "$TEAM" ] || printf '  <key>teamID</key><string>%s</string>\n' "$TEAM" )
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist"

APP="$OUT/$PRODUCT"
[ -d "$APP" ] || die "export produced no $PRODUCT. A Generic Xcode Archive with
       no export path usually means a nested target is missing SKIP_INSTALL."

# --- 5. Audit ---------------------------------------------------------------
# Everything here is free and each item has been an actual bug in some shipped
# Mac app. Running them takes two seconds; finding them from a user's report
# takes a week.
step "Auditing the export"
fail=0
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=1; fi; }

check "signature is valid, and --deep traverses the nested glue" \
      "codesign --verify --deep --strict '$APP' 2>/dev/null"
if [ "$HAS_GLUE" = 1 ]; then
  check "the AppKit glue is in Contents/PlugIns" \
        "[ -d '$APP/Contents/PlugIns/ChalkAppKitGlue.bundle' ]"
fi
check "no debug dylibs shipped" \
      "! find '$APP' -name '*.debug.dylib' -o -name '__preview.dylib' | grep -q ."
check "the binary is universal" \
      "lipo -archs '$APP/Contents/MacOS/$BINARY' | grep -q x86_64 && lipo -archs '$APP/Contents/MacOS/$BINARY' | grep -q arm64"
# Minification is invisible in a diff and its absence is invisible at runtime,
# so it is asserted by size. The floor is 30% under the measured 2026-08-19
# figure (997649 bytes); the ceiling is the unminified size, which is what
# would ship if the Release MINIFY=1 wiring were lost.
check "the web bundle is minified (js under 1.4 MB)" \
      "[ \$(stat -f%z '$APP/Contents/Resources/editor/bundle.js') -lt 1400000 ]"
check "the editor bundle is present and non-trivial" \
      "[ \$(stat -f%z '$APP/Contents/Resources/editor/editor.html') -gt 200 ]"
check "the build is stamped with its commit" \
      "/usr/libexec/PlistBuddy -c 'Print :CHALKGitCommit' '$APP/Contents/Info.plist' | grep -q '$COMMIT'"

ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
echo "  entitlements:"
echo "$ENTITLEMENTS" | grep -oE '<key>[^<]+</key>' | sed 's/<[^>]*>//g; s/^/    /' || echo "    (none)"
check "the app is not sandboxed" \
      "! grep -q 'com.apple.security.app-sandbox' <<< \"\$ENTITLEMENTS\""

[ "$fail" -eq 0 ] || die "the export audit failed. Do not send this build."

# --- 6. Notarisation and packaging -----------------------------------------
# ditto, not zip: it preserves the signature and the bundle's symlinks, which
# `zip -r` does not, and a resigned-looking app fails Gatekeeper differently.
ZIP="$OUT/${PRODUCT%.app}-$VERSION.zip"
if [ -n "$NOTARY" ]; then
  step "Notarising"
  # notarytool takes a zip; the ticket is then stapled to the app itself, so
  # the zip is rebuilt from the stapled app.
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  NOTARIZED=yes
else
  step "Notarisation (skipped: set CHALK_NOTARY_PROFILE with a Developer ID identity)"
  echo "  This build is not notarised. macOS will say \"Apple could not verify"
  echo "  this app is free of malware\"; the user opens it once with"
  echo "  System Settings > Privacy & Security > Open Anyway."
  NOTARIZED=no
fi

step "Packaging"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

{
  echo "Chalk $VERSION (build $BUILD)"
  echo "shell:      $SHELL_KIND"
  echo "commit:     $COMMIT"
  echo "built:      $BUILD_DATE"
  echo "identity:   $IDENTITY"
  echo "notarized:  $NOTARIZED"
  echo "toolchain:  $(xcodebuild -version | tr '\n' ' ')"
  echo "macOS:      $(sw_vers -productVersion)"
  echo
  echo "dSYM UUIDs (keep the xcarchive; these symbolicate a user's crash):"
  find "$ARCHIVE/dSYMs" -name '*.dSYM' -exec dwarfdump --uuid {} \; 2>/dev/null | sed 's/^/  /'
} > "$OUT/manifest.txt"

step "Done"
cat "$OUT/manifest.txt"
echo
echo "send: $ZIP"
echo "keep: $ARCHIVE"
