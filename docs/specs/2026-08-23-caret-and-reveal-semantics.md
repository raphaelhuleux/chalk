# Caret and reveal semantics

Status: normative.
This document is the single normative statement of caret and reveal behavior in Chalk's preview mode, for both languages.
The matrix runners (Tests/matrix) cite the rule IDs below when a cell fails; Tests/matrix/rules.mjs is the only permitted restatement of these rules in code.
Behavior the code exhibits but this spec does not bless is listed in section 8 (Decisions pending) rather than silently normalized.
Scope: the editor-core preview surface. Source mode is covered by R-X1 only.

## 1. Vocabulary

Construct: a source span that a preview plugin renders differently from plain text (a math region, a styled command, a marker pair, a fence region, a list item token, a table, an image command, a beamer frame).
Extent: the maximal source range a construct owns, written `[from, to)` in document offsets; for a LaTeX command the extent is `[cmdFrom, to+1)`, the backslash through one past the closing brace.
Hidden range: a source span currently replaced by a decoration (with or without a stand-in widget); abutting or overlapping hides read as one hidden range.
Reveal window: the set of selection states for which a construct shows its raw source instead of its rendered form.
Char-window: a reveal window of the form `[from, to)` over the selection head, active only for an empty caret; `to` is exclusive, so a caret one past the closing delimiter is outside.
Line-window: a reveal window over document lines; the construct reveals while an empty caret sits on one of the construct's lines, delimiter lines included; a non-empty selection follows the selection-on-line rule over the same lines.
Selection-on-line: a reveal window for fence lines; the fence reveals while an empty caret sits on the line, while a non-empty selection is anchored on the line, or while a selection end lies strictly inside the range the construct hides. A selection that only passes over the line, or ends on an edge of its hidden range, leaves it concealed.
Visual row: one rendered row of text; a soft-wrapped document line contributes several, a collapsed line contributes none, a block-replaced region contributes exactly one widget row.
Caret slot: a coordinate-addressable caret position on a visual row: every position in visible text plus the two edges of each hidden range.
Goal x: the horizontal pixel offset a run of vertical presses aims at; owned by a per-view session because CM6's per-range goalColumn does not survive a dispatch.
Stop: a vertical press claimed by a keymap that moves the caret exactly one document line onto a fence or display-block line instead of one visual row.
Collapsed fence: a fence line hidden together with its preceding line break, so the line occupies no visual row and its text merges into the previous rendered row.
HideTo absorption: a block widget's replace range extended through a directly following collapsed fence line, because the fence's own newline-absorbing hide would otherwise merge into a line the widget already consumed and leave a phantom empty row.
Conceal override: the transient conceal-everything state armed by a double-click after a release-reveal, so the second click measures pre-reveal geometry.
Preview widget: the read-only rendered block shown below a revealed display-math region while it is being edited.

## 2. Reveal rules

Each table row carries an ID (R-T1..R-T9, R-M1..R-M9) so a matrix failure can cite the exact reveal rule it contradicts.
The oracle invariants the matrix asserts over these tables:
O-1: no source outside a catalogued construct extent is ever hidden.
O-2: the hidden set (extents and block flags, after merging abutting ranges) equals the prediction rules.mjs derives from this section.
O-3: the DOM shows exactly the rows the hidden set implies (a block-covered line yields no row, a hidden leading newline merges the line into the previous row, everything else shows its unhidden text).
O-4: widget points and atomic ranges match the prediction: a preview widget exists exactly while a display region is revealed, and the GFM table block is the only atomic range.
O-5: concealment is a pure function of (document, selection, conceal override): returning to a selection state reproduces the identical hidden set.

### 2.1 LaTeX

| ID | Construct | Extent | Hidden when concealed | Reveal window | Widget click target | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| R-T1 | Inline math `$…$`, `\(…\)` | `[from, to)` | whole extent, MathWidget | char-window `[from, to)` | caret at `from` | conceal override forces the rendered form regardless of the caret. |
| R-T2 | Display math `\[…\]`, `$$…$$`, `equation`/`align`/… environments | `[from, to)` | one block replace `[blockFrom, hideTo)` | line-window over the construct's lines, selections included | caret at `from` | `blockFrom` is the line start when only whitespace precedes `from`, else `from` (R-T-block). `hideTo` extends through a following collapsed callout close fence when the block is the callout's last body element, and through following collapsed list close fences, unless a collapsed callout close fence follows those (hideTo absorption). Exempt from the conceal override. Preview widget after `to` while revealed; when `hideTo` would absorb a collapsed callout close fence, the preview sits after that fence line instead, so the fence hide keeps its merge host (no phantom row). |
| R-T3 | `\textbf{…}`, `\emph{…}`, `\texttt`, `\underline`, `\textsc`, heading commands `\section`/`\subsection`/`\subsubsection` | `[cmdFrom, to+1)` | prefix `[cmdFrom, argFrom)` and closing brace `[to, to+1)` | char-window `[cmdFrom, to+1)` | none (argument text is real text) | a heading's prefix hide carries the computed section-number pill. Nested commands conceal independently; abutting hides merge (`\textbf{\emph{` reads as one hidden range, so does `}}`). A caret on the outer closing brace reveals only the outer command. |
| R-T4 | `\ref{…}`, `\cite{…}`, `\label{…}` pills and `\footnote{…}` | `[cmdFrom, to+1)` | one replace over the whole extent, key/number pill | char-window `[cmdFrom, to+1)` | caret at `argFrom` (the key) | single-line commands only; a command spanning lines stays raw. Cite pills join their keys `(a; b)`. |
| R-T5 | `\href{url}{text}`, `\url{…}` | `[cmdFrom, to+1)` | prefix `[cmdFrom, textFrom)` and closing brace `[to, to+1)`; text marked as a live link | char-window `[cmdFrom, to+1)` | none | single-line only. Cmd/Ctrl+click on the link text opens the URL. |
| R-T6 | Theorem-family callout `\begin{theorem}…\end{theorem}` | fence lines | open fence line `[lineFrom, lineTo)` replaced by the label widget; close fence hidden `[prevLineEnd, closeLineEnd)` (collapsed fence) | selection-on-line, per fence | label click places the caret on the open fence line | body lines are never hidden by the callout. The close fence hide is suppressed when a block widget absorbed it (hideTo). |
| R-T7 | List env `\begin{itemize}` / `\begin{enumerate}` | fence lines and `\item` tokens | both fences collapsed `[prevLineEnd, fenceLineEnd)`; each `\item` token (plus trailing inline whitespace) replaced by its marker | fences: selection-on-line; items: char-window over the token | none | an open fence with `[args]` never collapses. A fence whose merge host a math block consumed emits no hide (the math absorbs it). An env with no items stays fully revealed. |
| R-T8 | Beamer frame `\begin{frame}{T}{S}` (beamer documentclass only) | fence lines | open fence line replaced by the header widget; `\end{frame}` text hidden `[lineFrom, lineTo)` with the ROW kept as the card's foot; common body indent hidden per line | selection-on-line, per line | header click places the caret on the fence line | the foot row is never collapsed. The `\frametitle` form instead collapses the bare open fence line and moves the band onto the `\frametitle` row. |
| R-T9 | `\includegraphics[…]{path}` | `[from, to)` | whole extent, ImageWidget | char-window `[from, to)` | none normative (see 8) | a command in a `%` comment renders nothing. |

### 2.2 Markdown

| ID | Construct | Extent | Hidden when concealed | Reveal window | Widget click target | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| R-M1 | Inline math `$…$` | `[from, to)` | whole extent, KaTeX widget | char-window `[from, to)` | caret at `from` | a span hard-wrapped across a source line keeps the same rules. |
| R-M2 | Display math `$$…$$` | `[from, to)` | one block replace `[blockFrom, hideTo)` | line-window, selections included | caret at the replace start | `blockFrom` snaps to the line start over leading whitespace (indented list-item math). `hideTo` absorbs a following collapsed callout close fence when the block is the callout's last body element. An UNCLOSED `$$` renders nothing: no hides, no widget, source stays visible. Preview widget after the block while revealed, moved past an absorbed collapsed callout close fence the same way as R-T2. |
| R-M3 | ATX heading `# …` | heading line | nothing, except a trailing `{#sec-…}` attribute, replaced (leading whitespace included) by a dimmed id pill | attribute: char-window over the whole heading, END INCLUSIVE `[from, to+1)` | none | the `#` marks are always visible by design. The pill mirrors R-T4's `\label{…}`: an id is what `@sec-…` points at, so it stays readable rather than vanishing. The window includes `to` because the attribute ends the line — the position after `}` is the only one past it, and excluding it made the id half-editable (2026-08-26). |
| R-M4 | Bold `**…**`, italic `*…*`, code `` `…` ``, strike `~~…~~`, highlight `==…==` | node extent | both delimiter runs hidden, text visible and styled | char-window over the node | none | |
| R-M5 | Link `[text](url)` | node extent | `[` hidden; `](url)` hidden; text marked as a live link | char-window over the node | none | Cmd/Ctrl+click opens the URL. |
| R-M6 | Image `![alt](src)` | node extent | whole extent, ImageWidget | char-window over the node | none normative (see 8) | single-line nodes only. |
| R-M7 | Blockquote `>` | marker | nothing is ever hidden | n/a | n/a | the marker is styled, dimmed while the caret is off the line. |
| R-M8 | Quarto callout `::: {…}` … `:::` | fence lines | open fence line replaced by the label widget; close fence collapsed `[prevLineEnd, closeLineEnd)`; a heading-title line collapses the same way | selection-on-line, per fence/title line | label click places the caret on the fence line | same core as the LaTeX callouts. |
| R-M9 | GFM table | table block | whole block replaced by the editable table widget, ALWAYS (no reveal window); the block is atomic | none | edits happen inside the widget's cells | `hideTo` absorbs a following collapsed callout close fence, selection-aware. |

## 3. Horizontal rules

R-H1: Left/Right move the selection head exactly one grapheme cluster per press (one line break counts as one step); hidden source is stepped through position by position, never skipped, because no construct is atomic except the GFM table.
R-H2: the GFM table block is the single atomic range: horizontal motion entering it lands on the far edge in one press, and the caret never rests strictly inside it under arrow motion.
R-H3: Home/End go to the boundary of the caret's VISUAL row and never leave the caret's document line; when a coordinate probe would land on another line the boundary is recomputed within the line; Home at an indented line start goes to the first non-space character first.
R-H4: Alt/Option+Arrow moves by word group on every platform.

## 4. Vertical rules

R-V1: Up/Down move an empty caret exactly one visual row per press; a press never skips a visual row and never lands on a row the user cannot see.
R-V2: the goal x is captured on the first press of a vertical run, preserved across every subsequent press of the run (through short lines, fence stops, and display-block entries), and dropped the moment anything other than a vertical press moves the caret; a later long line receives the caret at the run's original x.
R-V3: when the adjacent document line in the pressed direction is a collapsed fence line (callout close fence, callout title line, list open or close fence, or the collapsed bare open fence of a `\frametitle`-form frame), the press is a stop: the caret moves exactly one document line onto that fence, same column clamped to the target line length, and the fence reveals under it.
R-V4: when the adjacent document line starts (going down) or ends (going up) a concealed display-math block, the press enters the block on that fence line, same column clamped to the target line length; a revealed display block navigates as ordinary lines.
R-V5: a vertical landing that would fall inside a concealed inline-math region or a whole-command pill settles on the nearest region edge instead, and a landing inside a hidden `\cmd{` prefix settles on the first visible argument character (LaTeX only; Markdown landings cannot fall inside a replaced span, so it has no snap).
R-V6: every remaining wrapped row of the current document line is walked before any document-line stop (R-V3, R-V4) fires.
R-V7: the preview widget below a revealed display block is never a stop and never a landing; a rendered GFM table is crossed in one press, landing on the first position past it (down) or the last position before it (up), and is never entered vertically.
The crossing spans the table's parse node: a callout close fence absorbed into the table block travels with it, so vertical motion cannot stop on the absorbed fence (horizontal motion still reaches it).

## 5. Pointer rules

R-P1: click coordinates round-trip: a click at the coordinates of a visible caret slot places an empty caret at exactly that slot.
R-P2: a press on a rendered math widget (inline or display, both languages) or on a LaTeX pill places an empty caret inside the construct (region start for math, argument start for pills) and the raw source appears on button release; both halves of the widget behave identically (no dead zone).
R-P3: geometry is frozen while the button is down: no conceal or reveal reflow happens between press and release, a drag never reflows mid-gesture, and keyboard motion during a held press resyncs the frozen decorations immediately (LaTeX; the Markdown editor has no gesture tracker today, see 8).
R-P4: a double-click selects the word the user saw: when the second press lands within the undo window after a release-reveal, concealment is restored before the click is measured, so the word selection grabs exactly the pre-reveal text; presses that opened a widget never arm this undo.
R-P5: a touch tap bypasses the widget mousedown handlers (they stand down for two seconds after any touch) and resolves structurally; the full touch contract is a decision pending (see 8).

## 6. Selection and source-mode rules

R-S1: a non-empty selection never reveals a char-window construct; extending a selection cannot reflow the line under the highlight.
R-S2: line-window and selection-on-line constructs reveal for a selection only where it started or where an end would be stranded: a display block or fence stays revealed for a selection anchored on its lines, and reveals for an end strictly inside its hidden range. A selection that passes over one, or ends on an edge of it, never reveals it, so releasing a drag never reflows the document (owner report 2026-09-16: selecting through theorems and equations reopened their source on release and moved the selection end).
R-X1: in source mode nothing is hidden, no stop or snap keymap is active, and every motion is CodeMirror default motion.
R-X2: in Mixed view mode only the replaced-whole constructs (inline and display math, images, tables) have a reveal window; every delimited and fenced construct is permanently in its revealed state as dimmed source, the fence-stop keymaps are inactive, and every other motion is default motion. The math and table stops and the snap out of a widget stay active because those constructs still render.

## 7. Interactions worth naming

The stops compose in a fixed precedence: table crossing, then frame fence, then callout fence, then list fence, then display-math entry, then the default goal-x row move; the first claimant wins and R-V6 gates them all.
A fence stop landing on a fence line reveals it (selection-on-line), which restores the fence's visual row for as long as the caret stays; leaving re-collapses it.
HideTo absorption moves a hide between owners without changing the union of hidden source: O-2 predictions are stated on the merged union, so absorption is invisible to O-2 and only observable through O-3/O-4 and the widget's extent.
Dispatching a caret INTO a concealed region programmatically (or by click, R-P2) is legitimate and immediately applies that region's reveal window; the vertical rules only constrain how arrow presses travel.

## 8. Decisions pending (owner)

Triple-click on a line: whether the selection includes the trailing newline; currently fails fixture `Tests/fixtures/mouse/23-triple-click-line.txt` identically on every engine and stays in KNOWN_FAILURES.
Markdown widget right-half click for widgets without a mousedown handler (images, and any md widget other than math): CM6's default may place the caret at the exclusive end, outside the reveal window; not yet specified.
Touch tap on widgets: the mouse handlers stand down after touch and the structural resolution is untested on device; the tap contract (reveal on tap? caret placement?) is unspecified.
Home on a wrapped row of a hanging-indent list item: whether Home goes to the wrapped row's visual start (under the hanging indent) or to the marker column; unspecified.
The Markdown gesture tracker: R-P3/R-P4 are enforced by machinery registered only for LaTeX; whether Markdown needs the same freeze (its reveals also reflow) is undecided.
Which side of a zero-width hidden run a boundary or vertical landing chooses: the engine prefers the revealing side (End before a concealed trailing `}` reveals the command; a row landing past a collapsed fence's merge point lands on the fence line and reveals it); the matrix accepts either side by x-equality until this is decided.
