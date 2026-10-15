# Chrome reference

The frozen chrome geometry the AppKit shell is measured against
(docs/specs/2026-10-15-appkit-shell-rewrite-plan.md, "UI parity method").

`catalyst-2026-10.json` is every cell of the 32-state matrix as the Catalyst
shell laid it out on 2026-10-15, converted to Mac points (the Catalyst rects
divided by `ChalkMetrics.displayScale`). Format: `ChromeLayoutReference` in
ChalkKit.

Regenerate from the Catalyst build with:

```
TEST_RUNNER_CHALK_CHROME_REFERENCE_OUT="$PWD/Tests/chrome-reference/catalyst-2026-10.json" \
  xcodebuild test -project mac/Chalk.xcodeproj -scheme Chalk \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath mac/build/dd \
  -only-testing:ChalkTests/ChromeInvariantMatrixTests CODE_SIGNING_ALLOWED=NO
```

Only regenerate it for a deliberate chrome change on the Catalyst side; the
file is the port's target, not a snapshot that tracks the code.

The pixel reference is the showcase set under `docs/images/` (retaken by
`scripts/screenshots/capture-mac.sh`), not one image per cell.
