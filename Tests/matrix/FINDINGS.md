# Matrix findings

Real engine bugs the discovery matrix surfaced (2026-08-23 runs: chromium, webkit; 72 cells, ~26.5k checks per lane).
Severity: P0 = wrong caret or lost text visibility, P1 = annoyance.
Every entry has a KNOWN_CELLS.txt line; delete both together when a fix lands (a fixed entry stays below as a FIXED record naming its commit).
ALL FIVE FINDINGS FIXED 2026-08-24; KNOWN_CELLS.txt is empty and every cell is green on every engine lane.
One caret fixture per finding is promoted into Tests/fixtures/caret/ (29-33, commit 6896e43) so the plain fixture lane guards the fixes.

## 1. Phantom row under an absorbed callout fence (tex) — P1 — FIXED in 2caab3d

Cell `tex/display-3/absorb-callout/w80/desktop`, rule O-3.
Repro: tex `\begin{theorem}` / `lead body line` / `\[` / `E = mc^2` / `\]` / `\end{theorem}`, caret anywhere inside the math.
The revealed math drops its block preview widget at the math's end, which is exactly the collapsed `\end{theorem}` hide's merge host; the fence's newline-absorbing hide then renders a stray empty row outside the box.
Already recorded (untagged) in Tests/browser/KNOWN_FAILURES.txt; the matrix pins it per cell.
Root cause hypothesis: callout-core.ts:520 (`closingFenceHideRange` needs a merge host) colliding with the side-1 block preview widget at tex-math.ts:503.
Fix (2caab3d, shared with finding 2): callout-core's `displayPreviewPos` places the edit-mode preview AFTER the collapsed fence line (calloutBlockAt's hideTo) when the block is the callout's last body element, so the fence hide keeps its merge host; both math plugins call it, spec R-T2/R-M2 notes updated, jsdom twins added in callout-fence-collapse.test.ts, and the run.mjs `reveal oracle smoke` O-3 baseline entry is deleted (the check passes outright).

## 2. Phantom row, the md twin — P1 — FIXED in 2caab3d

Cell `md/display-3/absorb-callout/w80/desktop`, rule O-3.
Repro: md `::: {.callout-note}` / `lead body line` / `$$` / `E = mc^2` / `$$` / `:::`, caret inside the math.
Identical mechanism through md-math-plugin.ts:645 (KaTeXPreviewWidget, block, side 1); ENGINE-DIFFS.md carried this as "latent" and the matrix confirms it red on every engine lane.
Root cause hypothesis: same as finding 1 (the shared collapsed-fence idiom, callout-core.ts:520).
Fix: the same `displayPreviewPos` (see finding 1) — one change in the shared core, the hosts stay identical.

## 3. The goal column dies crossing a rendered table — P1 — FIXED in f33d9d6

Cells `md/table/plain/w80/desktop` and `md/table/absorb-callout/w80/desktop`, rule R-V2.
Repro: md prose line / GFM table / blank line / prose line; Down from column 18 of the top line; after the crossing the caret continues at column 0 (measured: start x 189.6, final x 6.0).
The table crossing itself lands at the far side's line start by design (R-V7), but the vertical-motion goal session should survive to aim the NEXT press back at the run's column, the way fence stops do.
Root cause hypothesis: table-field.ts:171 (`applyHead` dispatches without `dispatchVerticalStop`/`recordVerticalLanding`, so the session dies and the next press re-captures at the col-0 landing).
Fix (f33d9d6): `applyHead` now does the dispatchVerticalStop bookkeeping on all four bindings, Shift variants included; and the goal session is keyed on the recorded selection OBJECT identity instead of head equality, so a later click or programmatic caret move onto the previous landing position cannot resurrect a stale goal (R-V2's "dropped the moment anything other than a vertical press moves the caret", now literal).

## 4. Vertical motion skips an image-only line — P0 (confirmed with a resolvable asset) — FIXED in 3397633

Cell `tex/includegraphics/own-line/w80/desktop`, rule R-V1.
Repro: tex prose line / `\includegraphics[width=0.5\textwidth]{fig.png}` / prose line; Down from the top line lands on the BOTTOM line; the image line is unreachable vertically (Left/Right and clicks still reach it).
CONFIRMED with a real asset (stub `resolve-asset` bridge answering with a data URL of test-docs/figures/tiny.png): the bug reproduces whenever the rendered row is SHORTER than half the text height, and reclassified P0.
Root cause (measured, not the original hypothesis): CM6's `moveVertically` probes `textHeight >> 1` px past the current row's edge and accepts the first position whose row midline lies beyond the start row, so any widget row shorter than that probe distance is stepped over — an unresolved asset gives the img a 0x0 box (row height 0), and a small rendered image (the 8x8 tiny.png at `width=0.5\textwidth` renders 4px tall) is skipped identically.
The widget always had a resolvable caret position (coordsAtPos returns a rect at both edges); the row was simply too short for the coordinate probe.
Fix (3397633): `.cm-live-image` keeps a minimum caret-sized box (1lh tall with a 1.2em fallback, 1ch wide) so the row is a landing target while the image loads, after it fails, and for tiny images; css-guardrails.test.ts pins the minimums. The geometric runner now resolves assets for real (stub bridge answering resolve-asset with a tiny.png data URL), so the image cells test the rendered case; the unresolved case was verified reachable separately and fixture caret/30 guards it.

## 5. The landing snap settles inside a nested command's hidden prefix — P1 — FIXED in 6da32ef

Cell `tex/nested-bf-em/mid/w80/desktop`, rule R-V5, red on webkit (latent on chromium: its raw landings happen not to fall in the outer prefix).
Repro (webkit): tex `lead words \textbf{\emph{xy}} tail` between park lines; Down from column 11 of the line above lands the caret at the boundary between the hidden `\textbf{` and `\emph{` runs (position 48), which is inside the merged hidden range, and both commands pop open.
R-V5 says a landing in a hidden `\cmd{` prefix settles on the first VISIBLE argument character; for a nested command the outer argument's first characters are themselves hidden.
Root cause hypothesis: tex-vertical-motion.ts:69 (`snapped = r.from` takes the OUTER command's argument start without re-checking that the position is outside every hidden prefix; the fix is to iterate the snap to a fixpoint or prefer the innermost region's `from`).
Fix (6da32ef): `snapVerticalLanding` iterates the single-pass snap to a fixpoint (a seen-set stops the rare nearestEdge oscillation), still pure; unit tests extended with the outer-prefix and triple-nesting cases.

## Decisions surfaced (not bugs, folded into the spec's section 8)

At a zero-width hidden run the engine prefers the REVEALING side for boundary and vertical landings (End before a concealed trailing `}` reveals the command; a row landing past a collapsed fence's merge point lands on the fence line and reveals it); the matrix accepts either side by x-equality.
A callout close fence absorbed into a table block travels with the table for vertical motion and is vertically unreachable (spec R-V7 note).
GFM lazy continuation makes a table swallow any directly following non-blank line as a row; the composer models documents with the customary blank line after a table.
