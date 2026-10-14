import { describe, it, expect } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import {
  revealSource,
  revealReplacedSource,
  revealReplacedSourceInclusive,
  revealDelimitedSource,
  revealDelimitedSourceInclusive,
} from '../src/editor/reveal';

/**
 * Inline live-preview spans (bold/italic/link/code/…) hide their markdown
 * markers and reveal the raw source when the caret is inside, so you can edit
 * them. Revealing widens the line (the markers reappear), which reflows text.
 * During a selection that reflow shifts the highlighted text out from under the
 * caret, so the reveal must fire ONLY for a collapsed caret — never while a
 * (non-empty) selection is being made.
 *
 * A span that is REPLACED whole while concealed (inline math, an image, a
 * pill) needs the second rule below: a selection cannot live inside a replace
 * widget, so re-concealing under one ejects the caret from the construct.
 */
describe('revealSource', () => {
  const from = 10;
  const to = 20; // half-open [from, to)

  it('reveals when a collapsed caret is inside the span', () => {
    expect(revealSource(EditorSelection.cursor(15), from, to)).toBe(true);
    expect(revealSource(EditorSelection.cursor(10), from, to)).toBe(true); // opening delimiter
  });

  it('does not reveal when a collapsed caret is outside the span', () => {
    expect(revealSource(EditorSelection.cursor(9), from, to)).toBe(false);
    expect(revealSource(EditorSelection.cursor(20), from, to)).toBe(false); // to is exclusive
  });

  it('does NOT reveal when a non-empty selection head is inside the span', () => {
    // The regression: selecting into bold used to reveal the markers mid-drag,
    // reflowing the line so the highlight no longer matched the caret.
    expect(revealSource(EditorSelection.range(0, 15), from, to)).toBe(false);
  });

  it('does not reveal when a non-empty selection head is outside the span', () => {
    expect(revealSource(EditorSelection.range(0, 25), from, to)).toBe(false);
  });
});

describe('revealReplacedSource', () => {
  const from = 10;
  const to = 20;

  it('matches revealSource for a collapsed caret', () => {
    expect(revealReplacedSource(EditorSelection.cursor(15), from, to)).toBe(true);
    expect(revealReplacedSource(EditorSelection.cursor(10), from, to)).toBe(true);
    expect(revealReplacedSource(EditorSelection.cursor(9), from, to)).toBe(false);
    expect(revealReplacedSource(EditorSelection.cursor(20), from, to)).toBe(false);
  });

  it('keeps revealing while a non-empty selection stays inside the span', () => {
    // Shift+Arrow inside inline math. Re-concealing here would put the
    // selection inside a replace widget, which has no position to hold it.
    expect(revealReplacedSource(EditorSelection.range(15, 13), from, to)).toBe(true);
    expect(revealReplacedSource(EditorSelection.range(13, 15), from, to)).toBe(true);
    expect(revealReplacedSource(EditorSelection.range(10, 15), from, to)).toBe(true);
  });

  it('leaves the span rendered when the selection covers it exactly', () => {
    // Both ends sit on the widget's outer edges, where the rendered form holds
    // them fine. This is what a drag ACROSS the formula produces (while
    // concealed, coordinates resolve only to the two edges), so revealing here
    // would flash the source open mid-drag.
    expect(revealReplacedSource(EditorSelection.range(10, 20), from, to)).toBe(false);
    expect(revealReplacedSource(EditorSelection.range(20, 10), from, to)).toBe(false);
  });

  it('counts a selection ending on the closing delimiter as inside', () => {
    // A caret at `to` is outside, but a range anchored inside and ending there
    // is still editing the span.
    expect(revealReplacedSource(EditorSelection.range(15, 20), from, to)).toBe(true);
  });

  it('does not reveal when the selection crosses an edge', () => {
    expect(revealReplacedSource(EditorSelection.range(0, 15), from, to)).toBe(false);
    expect(revealReplacedSource(EditorSelection.range(15, 25), from, to)).toBe(false);
    expect(revealReplacedSource(EditorSelection.range(0, 25), from, to)).toBe(false);
  });

  it('does not reveal for a selection wholly outside the span', () => {
    expect(revealReplacedSource(EditorSelection.range(0, 5), from, to)).toBe(false);
    expect(revealReplacedSource(EditorSelection.range(20, 25), from, to)).toBe(false);
  });
});

/**
 * A construct that hides only its DELIMITERS strands a selection just as badly
 * as a whole-span replace does — but only when an end lands inside a delimiter.
 * `A **bold** word` with the caret between the two opening asterisks, then
 * Shift+Left, used to re-hide both markers and drop the selection into them:
 * the keystroke replaced `**` instead of the one `*` that was selected.
 *
 * The visible argument is the case that must NOT reveal: a double-click
 * word-select over `\emph{word}` sits entirely on visible text, and revealing
 * there would reflow the line right after the gesture (tex-conceal-plugin.ts).
 */
describe('revealDelimitedSource', () => {
  // `**bold**` at 10: markers 10..12 and 16..18, argument 12..16.
  const from = 10;
  const openTo = 12;
  const closeFrom = 16;
  const to = 18;
  const reveal = (main: EditorSelection['main'] | ReturnType<typeof EditorSelection.range>) =>
    revealDelimitedSource(main, from, to, openTo, closeFrom);

  it('matches revealSource for a collapsed caret', () => {
    expect(reveal(EditorSelection.cursor(14))).toBe(true);
    expect(reveal(EditorSelection.cursor(10))).toBe(true);
    expect(reveal(EditorSelection.cursor(18))).toBe(false); // past the closing marker
    expect(reveal(EditorSelection.cursor(9))).toBe(false);
  });

  it('reveals when a selection end lands inside the opening marker', () => {
    expect(reveal(EditorSelection.range(11, 10))).toBe(true); // one `*` selected
    expect(reveal(EditorSelection.range(11, 14))).toBe(true); // marker into the word
  });

  it('reveals when a selection end lands inside the closing marker', () => {
    expect(reveal(EditorSelection.range(16, 17))).toBe(true);
  });

  it('leaves the markers hidden for a selection on the visible argument', () => {
    // The double-click word-select. Both ends sit on text that is on screen
    // either way, so nothing is stranded and nothing must reflow.
    expect(reveal(EditorSelection.range(12, 16))).toBe(false);
    expect(reveal(EditorSelection.range(13, 15))).toBe(false);
  });

  it('leaves them hidden when the selection crosses an edge or covers the span', () => {
    expect(reveal(EditorSelection.range(5, 14))).toBe(false);
    expect(reveal(EditorSelection.range(14, 25))).toBe(false);
    expect(reveal(EditorSelection.range(10, 18))).toBe(false);
  });
});

/**
 * The inclusive variants: a construct that ENDS A LINE has no position past its
 * closing delimiter, so the caret at `to` is still inside it (the Quarto
 * heading id, the markdown crossref pill).
 */
describe('the inclusive variants', () => {
  it('revealReplacedSourceInclusive counts the end position as inside', () => {
    expect(revealReplacedSourceInclusive(EditorSelection.cursor(20), 10, 20)).toBe(true);
    expect(revealReplacedSource(EditorSelection.cursor(20), 10, 20)).toBe(false);
  });

  it('revealReplacedSourceInclusive keeps a contained selection revealed', () => {
    expect(revealReplacedSourceInclusive(EditorSelection.range(15, 18), 10, 20)).toBe(true);
    expect(revealReplacedSourceInclusive(EditorSelection.range(5, 15), 10, 20)).toBe(false);
  });

  it('revealDelimitedSourceInclusive reveals only for an end inside a hide', () => {
    // A Quarto heading: the whole line is the window, only `{#sec-one}` hides.
    const line = { from: 0, to: 20 };
    const attrFrom = 8;
    const r = (main: ReturnType<typeof EditorSelection.range>) =>
      revealDelimitedSourceInclusive(main, line.from, line.to, line.from, attrFrom);
    expect(r(EditorSelection.range(10, 12))).toBe(true); // inside the id
    expect(r(EditorSelection.range(2, 5))).toBe(false); // in the heading text
    expect(r(EditorSelection.cursor(20))).toBe(true); // caret past the id
  });
});
