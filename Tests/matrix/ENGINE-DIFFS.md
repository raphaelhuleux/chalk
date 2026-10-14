# Engine matrix: chromium vs webkit

Run 2026-08-23 against the web/dist bundle built the same evening, playwright 1.62.1, WebKit 2336, `--no-build` after one build.
Lanes come from Tests/runner/lib/browser.mjs.

## Results

| Suite | Cases/checks | chromium | webkit | Analysis |
| --- | --- | --- | --- | --- |
| Tests/fixtures caret fixtures (48) | 47 fixtures | all pass | all pass | no engine difference observed |
| Tests/fixtures/mouse/23-triple-click-line.txt | 1 fixture | known-fail | known-fail | fails identically on every engine: the triple-click paragraph-vs-line question is CodeMirror policy, not engine behavior, so the existing untagged KNOWN_FAILURES entry stays untagged |
| Tests/browser/run.mjs (22 scenarios) | 142 checks | all pass | all pass | no engine difference observed |
| Tests/browser reveal oracle smoke (added by A2; 23rd scenario) | 5 checks | 4 pass + 1 xfail | 4 pass + 1 xfail | the O-3 xfail is the phantom-row product bug recorded (untagged) in Tests/browser/KNOWN_FAILURES.txt; it fails byte-identically on every engine, so it is CodeMirror/plugin behavior, not an engine difference |

## Reading

No fixture or scenario behaves differently across the lanes, so no tagged entries were seeded in either KNOWN_FAILURES file.
The shipped engine is WKWebView, and until tonight every geometric assertion had only ever run in Chromium; the green webkit lane upgrades those 189 checks from "true in a browser Chalk never ships in" to "true in the shipped engine family".
That the matrix is clean is itself the recorded finding; the lanes exist so the next divergence lands in this table instead of in the app.

## Harness notes

The monospace-font guard in caret-fixtures.mjs (`i` vs `W` advance) passed in headless WebKit, so no font-fallback harness fix was needed.
The Mod-key fallback already present in run.mjs (`Control+Shift+Semicolon` then `Meta+Shift+Semicolon`) covered the webkit lane; no timing changes were needed.
