# Release steps

Chalk ships in two places:

| Product | Channel |
| --- | --- |
| Chalk for Mac | Direct download, signed with a Developer ID and notarised |
| Chalk for VS Code | VS Code Marketplace and Open VSX |

A Mac App Store listing is possible later, but it is blocked today (see the last section).

## Mac: direct download

### One-time setup

You need a paid Apple Developer Program membership for a notarised build.

1. Create a "Developer ID Application" certificate in your developer account and install it in the login keychain.
   Check it with `security find-identity -v -p codesigning`.
2. Store a notarytool keychain profile:
   `xcrun notarytool store-credentials <profile> --apple-id <apple-id> --team-id <TEAM_ID> --password <app-specific-password>`.
3. Keep the certificate and its private key backed up.
   The signing identity is part of the app's identity: if it changes, macOS asks every user for folder permissions again.

The bundle identifier comes from `bundleIdPrefix` in `mac/project.yml`.
A fork that ships its own build must change it.

### Build

1. Commit everything. The release script refuses a dirty tree, because a build that does not match a commit cannot be debugged against a report.
2. Run `scripts/check.sh` once by hand and read any failure. The release script runs it again as its gate, and any failure stops the release. `docs/known-failing-tests.md` lists the known intermittents.
3. Run the release script:

   ```bash
   CHALK_SIGN_IDENTITY="Developer ID Application: <name> (<TEAM_ID>)" \
   CHALK_TEAM_ID=<TEAM_ID> \
   CHALK_NOTARY_PROFILE=<profile> \
   ./scripts/release-mac.sh
   ```

The script archives, exports, audits the export, notarises, staples the ticket and zips the stapled app.
Everything lands in `dist/<version>-<build>/`.
Keep `Chalk.xcarchive`: its dSYMs are the only way to symbolicate a crash report from that build.

The notarised path turns on the hardened runtime. Under the hardened runtime the app only loads code signed by the same team, which includes the `ChalkAppKitGlue` bundle. This path has not been exercised end to end yet, so check the glue loads (the audit and `scripts/install-mac.sh` both describe how).

### Verify

On a Mac that has never seen the app:

- `spctl -a -vv Chalk.app` says `accepted`, source `Notarized Developer ID`.
- `xcrun stapler validate Chalk.app` succeeds.
- A double-click opens the app with no warning, and the editor shows text.

### Without a paid account

Leave out `CHALK_TEAM_ID` and `CHALK_NOTARY_PROFILE` and pass a self-signed identity instead.
Create one in Keychain Access (Certificate Assistant > Create a Certificate, type "Code Signing").
Self-signed is better than ad hoc for anything you hand out, because a stable identity lets macOS remember folder permissions across updates.
macOS will warn that it cannot verify the app; the user opens it once with System Settings > Privacy & Security > Open Anyway.

### Things to know

- The direct-download build is not sandboxed. The App Sandbox makes the editor's web view crash-loop (`docs/issues/2026-08-19-sandbox-crash-loops-the-webview.md`), so the release script blanks `CODE_SIGN_ENTITLEMENTS` and its audit fails a sandboxed export. Turning the sandbox on later would also move preferences and saved state into a container and strand existing users' settings.
- The deployment target is macOS 14. Test on the oldest macOS you claim to support before a release.
- There is no update mechanism yet. Users download each new version by hand.

## VS Code extension

1. Bump `version` in `vscode/package.json`.
2. Make sure `vscode/` has a `README.md` (the Marketplace page is built from it), a `CHANGELOG.md` and a `LICENSE`.
3. Build the package: `pnpm -C vscode package`. Check the file list with `npx vsce ls` from `vscode/`; it should include the licence and `THIRD-PARTY-NOTICES` if you ship one.
4. Publish with `vsce publish` (needs the publisher's Azure DevOps token) and `ovsx publish` (Open VSX, used by VSCodium, Cursor and other Code - OSS builds).

## Mac App Store (optional, blocked)

The Mac App Store requires the App Sandbox, and the sandbox breaks the editor today (see the issue note above).
`mac/Chalk/Chalk-macCatalyst.entitlements` already holds the sandbox entitlements, and `mac/Chalk/PrivacyInfo.xcprivacy` declares no tracking and no data collection.
Until the sandbox problem is solved, do not start an App Store submission.
