# Tabout — Design

**Date:** 2026-04-28
**Status:** Approved (pending user spec review)
**Scope:** Both `.tex` and `.md` editors

## Goal

Pressing `Tab` while the cursor is inside a math context jumps the
caret past the next closing scope. Repeated presses unwrap nested
scopes. Outside math, `Tab` retains its existing meaning (snippet
advance → autocomplete-accept → indent).

Inspired by Obsidian-Latex-Suite's "Tabout"; a generalisation of
Gilles Castel's `$0`-after-snippet-close convention so that
hand-typed math benefits too.

## Decisions

| #   | Question                | Choice                                          |
| --- | ----------------------- | ----------------------------------------------- |
| 1   | Languages               | Tex + Markdown                                  |
| 2   | `\left…\right` handling | Treat as one unit — jump past `\right⟨delim⟩`   |
| 3   | Outside-math behaviour  | Strictly math-gated; no-op outside math         |
| 4   | Reverse direction       | Out of scope for v1 (no Shift+Tab)              |
| 5   | `\rangle` / `\rvert`    | Out of scope for v1 (uncommon in this codebase) |

## Algorithm

Given cursor at position `p` and the editor state:

```
if !isInMathContext(state, p):     return false          // fall through
if hsnips has active tabstop:      return false          // hsnips owns Tab
target = scanForExit(state.doc, p)
if target == null:                 return false          // EOF / nothing
dispatch selection := cursor(target)
return true
```

`scanForExit` walks forward from `p` and returns the position **just
past** the first exit it finds:

| Token at scan position                     | Action                                                                                    |
| ------------------------------------------ | ----------------------------------------------------------------------------------------- |
| `\\`, `\$`, `\{`, `\}`, `\%`               | Skip 2 chars (escape)                                                                     |
| `%` (tex only)                             | Skip to end of line                                                                       |
| `\left⟨c⟩` where c ∈ `({[<.\|`/letter-form | Push `LEFT_GROUP`, advance past `\left⟨c⟩`                                                |
| `\right⟨c⟩` where c ∈ above                | If stack non-empty, pop & advance past it. Else **return position-just-past `\right⟨c⟩`** |
| `}`, `]`, `)`                              | **Return position-just-past it**                                                          |
| `$$`                                       | Math close — return position-just-past it                                                 |
| `$`                                        | Math close — return position-just-past it                                                 |
| `\)`                                       | Math close — return position-just-past it                                                 |
| `\]`                                       | Math close — return position-just-past it                                                 |
| `\end{…}`                                  | Math close — return position-just-past it                                                 |
| any other char                             | Advance 1                                                                                 |

The scanner does **not** track `{`/`[`/`(` opens — they are
inert in this scan because we want repeated Tab to step out one
scope at a time. The scan stops at the *first* unmatched closing
delim (which by the time we reach it from cursor position is
necessarily an exit boundary, since any `{` after the cursor that
gets balanced internally is fine — its matching `}` is past our
exit anyway, and the scanner stops at the *first* close).

## Worked examples

| Before                            | After Tab                         |
| --------------------------------- | --------------------------------- |
| `$\frac{a\|}{b}$`                 | `$\frac{a}\|{b}$`                 |
| `$\frac{a}\|{b}$`                 | `$\frac{a}{b}\|$`                 |
| `$\frac{a}{b}\|$`                 | `$\frac{a}{b}$\|`                 |
| `$\sin(x\|)$`                     | `$\sin(x)\|$`                     |
| `$[a, b\|]$`                      | `$[a, b]\|$`                      |
| `$\left(a\|\right) + b$`          | `$\left(a\right)\| + b$`          |
| `$x\|$`                           | `$x$\|`                           |
| `$x$\|`                           | (fall through — no-op)            |
| `\section{a\|}`                   | (fall through — outside math)     |
| `\begin{align}\nx\|\n\end{align}` | `\begin{align}\nx\n\end{align}\|` |

## File layout

New: `src/webview/editor/tabout.ts`

```typescript
export function taboutKeymap(
  isInMathContext: (state: EditorState, pos: number) => boolean,
  hasActiveSnippet: (state: EditorState) => boolean,
): Extension
```

Returns a `Prec.high` keymap binding `Tab` to a single command.
Language-agnostic — both editors get the same scanner; only the
math-context predicate differs.

Edits:
- `src/webview/editor/setup.ts` — wire into both tex and md arms
  after `hsnipsExtension(...)` but before the existing
  `keymap.of([{ key: 'Tab', run: acceptCompletion }])`.
- `src/webview/editor/hsnips-plugin.ts` — expose `hasActiveSnippet`
  predicate (or equivalent — small additive API).

## Tests

New: `test/unit/tabout.test.ts`

| Case                                          | Expectation                     |
| --------------------------------------------- | ------------------------------- |
| Tab outside math                              | returns false, cursor unchanged |
| Tab inside `$x\|$`                            | cursor → after `$`              |
| Tab inside `$\frac{a\|}{b}$`                  | cursor → after first `}`        |
| Tab repeated through nested braces            | unwraps one at a time           |
| Tab inside `\left(a\|\right)`                 | cursor → after `\right)`        |
| Tab past balanced inner `\left/\right`        | doesn't pop wrong scope         |
| Tab inside `\begin{align}…\|…\end{align}`     | cursor → after `\end{align}`    |
| Tab at EOF inside open math                   | falls through                   |
| Escape handling: `\}` is not an exit          | skipped correctly               |
| Comment handling (tex): `% }` doesn't trigger | skipped                         |
| Markdown variant (`$$…$$` block)              | same exits as tex               |

## Non-goals

- `\rangle`, `\rvert` (rare in this codebase; can add later)
- Reverse Shift+Tab
- Tabout outside math contexts
- Visual hint that Tab will exit (e.g. status bar)
