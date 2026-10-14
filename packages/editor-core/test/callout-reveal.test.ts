import { describe, it, expect } from 'vitest';
import { EditorState, EditorSelection, SelectionRange } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { buildCalloutDecorations } from '../src/editor/callout-core';
import { scanCallouts } from '../src/editor/md-callout-plugin';

// A callout whose open fence carries an editable name attribute. Line 1 is the
// open fence, line 2 body, line 3 close.
const SRC = '::: {#thm-pythagoras name="Pythagoras"}\nFor a right triangle.\n:::';

function stateWith(sel: SelectionRange): EditorState {
  return EditorState.create({
    doc: SRC,
    selection: EditorSelection.create([sel]),
    extensions: [markdown()],
  });
}

/** Whether a replace decoration (the label widget) covers the whole open line. */
function openLineReplaced(state: EditorState): boolean {
  const decos = buildCalloutDecorations(state, scanCallouts);
  const open = state.doc.line(1);
  let replaced = false;
  decos.between(open.from, open.to, (from, to, deco) => {
    // The label widget spans the full open line and is a replace (has a widget);
    // the line decoration is a zero-length point at line start.
    if (from === open.from && to === open.to && deco.spec.widget) replaced = true;
  });
  return replaced;
}

describe('callout open-fence reveal during selection', () => {
  const nameEnd = SRC.indexOf('Pythagoras') + 'Pythagoras'.length; // caret after the word
  const nameStart = SRC.indexOf('Pythagoras');

  it('shows the label widget when the caret is off the open line', () => {
    // caret in the body (line 2) — open fence collapses to its widget.
    expect(openLineReplaced(stateWith(EditorSelection.cursor(SRC.indexOf('For'))))).toBe(true);
  });

  it('reveals the raw source when an empty caret sits on the open line', () => {
    expect(openLineReplaced(stateWith(EditorSelection.cursor(nameEnd)))).toBe(false);
  });

  it('keeps the raw source revealed while selecting a word on the open line', () => {
    // Opt+Shift+Left result: a non-empty selection anchored at the word end.
    const sel = EditorSelection.range(nameEnd, nameStart);
    expect(openLineReplaced(stateWith(sel))).toBe(false);
  });
});
