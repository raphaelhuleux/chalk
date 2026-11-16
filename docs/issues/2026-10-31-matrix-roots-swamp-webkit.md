# The chrome transition matrix swamped the Mac with WebContent processes

Status: **fixed, 2026-10-31.**

## Symptom

`testEveryOrderedPairOfTogglesAndItsInversePairLandsOnTheFreshState` ran past 30 minutes with the test host beach-balling, and macOS offered to force quit it.
There were 469 WebContent processes and 630,000 `ExceededProcessCountLimit` log lines.

## Cause

The matrix builds hundreds of roots inside one test method, and nothing released them:

- Replacing a root did not close its tabs.
- Each root stayed in the test method's autorelease pool until the method returned. A root built inside `autoreleasepool` deallocated at once; the same work without it climbed about 17 processes a second.

Whether this predates the trailing slot's fourth state was not measured; that state only adds paths.

## Fix

- `ChromeMatrixHost.makeRoot` closes the outgoing root's tabs, and the matrix loops build each root in an `autoreleasepool`.
- `makeRoot` stops the run past 8 surfaces. The count is `WebEditorSurface.liveCountForTesting`, decremented in `deinit`: `teardown()` leaves the process running, so counting it misses this leak.
- `scripts/check.sh` runs Xcode tests with a 15 minute limit per test.

The pair test now takes about 2.5 minutes and peaks near 24 processes.
Regression: `ChromeTransitionMatrixTests.testAReplacedRootReleasesItsWebViews`.
