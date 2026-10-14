# The discovery matrix

The matrix mechanically checks the caret/reveal spec ([docs/specs/2026-08-23-caret-and-reveal-semantics.md](../../docs/specs/2026-08-23-caret-and-reveal-semantics.md)) against the live engine, construct by construct and context by context.
[catalogue.mjs](catalogue.mjs) owns the construct snippets and their structural metadata; [compose.mjs](compose.mjs) places them into contexts and produces cells with absolute offsets; [rules.mjs](rules.mjs) is the only code restatement of the spec and every expectation comes from it or from a coordsAtPos scan, never from recorded output.

## Running

Structural lane (jsdom, runs inside `pnpm test`): `pnpm --filter @chalk/editor-core test -- matrix-structural`.
Geometric lane (Playwright over the built web bundle): `pnpm test:matrix:geo` (chromium), `pnpm test:matrix:geo:webkit`; add `--no-build` to reuse `web/dist`, `--filter <substr>` to run a subset of cells, `--emit <cellId>` to print a promotable caret fixture for a cell.
Failure lines are `FAIL <cellId> <ruleId>` followed by `exp`/`got` lines; every line carries the engine tag.

## The KNOWN_CELLS discipline

[KNOWN_CELLS.txt](KNOWN_CELLS.txt) is the accepted-failure baseline for the geometric lane, one line per entry: `cellId ruleId [@tag]` (tags are the engine lanes; an untagged entry applies to every lane).
A listed entry that fails prints `xfail`; a listed entry that passes prints XPASS and FAILS the run, so entries cannot go stale.
The file is shrink-only by convention: entries are added only with a comment naming the finding (every entry must correspond to a FINDINGS.md item) and are deleted the moment the fix lands.
When a cell fails, decide honestly before touching anything: an engine bug goes to KNOWN_CELLS with a comment and a one-line repro (and a FINDINGS.md entry); a rules.mjs error is fixed in rules.mjs to match the SPEC; a spec error is fixed in the spec with the reasoning in the commit message; a harness bug is fixed in the runner.

## Known model gaps (deliberate)

The rare stack "list close fence, then a collapsed callout close fence, directly below a display block" (where the engine keeps the list fence revealed) is not composed; rules.mjs carries the guard but no cell exercises it.
Cells are trimmed per construct (each catalogue entry names its contexts) rather than sampled randomly, so a construct's absent context is a decision you can read in catalogue.mjs.

## Mutation checks

The oracle is only trustworthy if it goes red when the engine's predicates are wrong.
Three predicate flips are the standing check; run each once after significant matrix changes, watch the counts, and revert:

1. `revealSource` in md-live-preview.ts flipped to `head <= to`: proven in commit 57caf6e against the jsdom oracle (three boundary tests red).
2. tex-math's inline predicate flipped to `cursor <= r.to`: proven in the same commit (tex inline boundary red).
3. The goal-x session read disabled in callout-core.ts (`verticalGoalX` ignoring the stored session, capturing fresh every press): R-V2 goal-run cells must go red.

Recorded run (2026-08-23, each flip applied alone, then reverted; bundle rebuilt for the geometric checks):

- Flip 1 (`revealSource` to `head <= to`, md-live-preview.ts): structural lane 38 of 67 cells red (every cell with a char-window construct in EITHER language — revealSource feeds tex conceal, lists and images too), first violation `O-2/R-M1 head=45: exp [40,45) got (none)` (the exclusive end now reveals); geometric spot check `--filter md/inline-math/mid/w80` red with `FAIL md/inline-math/mid/w80/desktop R-M1, walk head=45: exp [40,45) got (none)`.
- Flip 2 (tex-math inline predicate to `cursor <= r.to`): structural lane exactly the 9 tex inline-math cells red (`O-2/R-T1 head=45: exp [40,45) got (none)` and the head=46 neighbour), everything else green — the flip is scoped and the oracle localizes it.
- Flip 3 (goal-x session read disabled in callout-core.ts `verticalGoalX`): geometric lane 43 of 72 cells red on R-V2 (every goal-run whose crossing passes a stop, a fence, a widget row or a short line re-captures at the clamped landing and never returns to its column); the structural lane stays green, as expected — R-V2 is pure geometry.
