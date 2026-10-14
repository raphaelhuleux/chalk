import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * A selection that merely passes over a line-level construct must leave it
 * rendered.
 *
 * Callout fences and titles, list fences, slide-card fences and display-math
 * blocks are revealed for editing while the caret sits on their line. They used
 * to be revealed for any selection OVERLAPPING the line (display math: any
 * selection whose head was on it), so selecting a paragraph through a theorem
 * reopened `\begin{theorem}`/`\end{theorem}` the moment the mouse was released:
 * rows appeared, everything below shifted, and the selection end re-resolved
 * against the moved text (owner report, 2026-09-16).
 *
 * Two cases still reveal, and are pinned here so the fix cannot overshoot:
 *  - the selection STARTED on the line (its anchor is there), so extending a
 *    selection from a caret-revealed fence never collapses it mid-selection;
 *  - a selection end sits strictly inside the text the construct hides, where
 *    it has no DOM position (see reveal.ts, fact 2).
 */

afterEach(destroyViews);

const text = (view: EditorView): string =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';

function select(doc: string, language: Language, anchor: number, head: number): EditorView {
  const view = langView(doc, language, { ensureTree: true, cursor: doc.length });
  view.dispatch({ selection: EditorSelection.range(anchor, head) });
  return view;
}

const at = (doc: string, needle: string, offset = 0): number => {
  const i = doc.indexOf(needle);
  if (i < 0) throw new Error(`fixture has no ${JSON.stringify(needle)}`);
  return i + offset;
};

describe('md callout under a selection', () => {
  const DOC = 'Intro paragraph.\n\n::: {#thm-a name="Alpha"}\nBody line one.\n:::\n\nOutro paragraph.';

  it('stays rendered when the selection passes over the whole box', () => {
    const view = select(DOC, 'md', at(DOC, 'Intro', 2), at(DOC, 'Outro', 3));
    expect(text(view)).not.toContain('{#thm-a');
    expect(text(view).match(/:::/g)).toBeNull();
  });

  it('keeps the close fence collapsed when the selection ends at the box end', () => {
    // Dragging to the right of the last body row resolves past the collapsed
    // fence, onto the end of its line: an edge, not a stranded position.
    const closeEnd = at(DOC, ':::\n\nOutro') + 3;
    const view = select(DOC, 'md', at(DOC, 'Intro', 2), closeEnd);
    expect(text(view).match(/:::/g)).toBeNull();
  });

  it('keeps the box rendered for a selection ending on the label row edge', () => {
    const openStart = at(DOC, '::: {#thm-a');
    const view = select(DOC, 'md', at(DOC, 'Outro', 3), openStart);
    expect(text(view)).not.toContain('{#thm-a');
  });

  it('keeps a titled box folded when the selection passes over its title', () => {
    const doc = 'Intro.\n\n::: {#thm-x}\n## Pythagorean Theorem\n\nbody\n:::\n\nOutro.';
    const view = select(doc, 'md', at(doc, 'Intro', 1), at(doc, 'Outro', 2));
    expect(text(view)).not.toContain('## Pythagorean');
  });

  it('stays revealed when the selection starts on the open fence', () => {
    const view = select(DOC, 'md', at(DOC, 'Alpha', 2), at(DOC, 'Outro', 3));
    expect(text(view)).toContain('{#thm-a');
  });

  it('reveals the close fence when a selection end is stranded inside it', () => {
    const view = select(DOC, 'md', at(DOC, 'Body'), at(DOC, ':::\n\nOutro', 1));
    expect(text(view)).toContain(':::');
  });
});

describe('tex callout under a selection', () => {
  const DOC =
    'Intro paragraph.\n\n\\begin{theorem}[Pythagoras]\nBody line.\n\\end{theorem}\n\nOutro.';

  it('stays rendered when the selection passes over the whole box', () => {
    const view = select(DOC, 'tex', at(DOC, 'Intro', 2), at(DOC, 'Outro', 3));
    expect(text(view)).not.toContain('\\begin{theorem}');
    expect(text(view)).not.toContain('\\end{theorem}');
  });

  it('stays rendered when the selection ends inside the body', () => {
    const view = select(DOC, 'tex', at(DOC, 'Intro', 2), at(DOC, 'Body', 2));
    expect(text(view)).not.toContain('\\begin{theorem}');
    expect(text(view)).not.toContain('\\end{theorem}');
  });

  it('stays revealed when the selection starts on the close fence', () => {
    const view = select(DOC, 'tex', at(DOC, '\\end{theorem}', 13), at(DOC, 'Intro', 2));
    expect(text(view)).toContain('\\end{theorem}');
  });
});

describe('tex list under a selection', () => {
  const DOC = 'Intro.\n\\begin{itemize}\n\\item one\n\\item two\n\\end{itemize}\nOutro.';

  it('keeps both fences collapsed when the selection passes over the list', () => {
    const view = select(DOC, 'tex', at(DOC, 'Intro', 1), at(DOC, 'Outro', 2));
    expect(text(view)).not.toContain('\\begin{itemize}');
    expect(text(view)).not.toContain('\\end{itemize}');
  });
});

describe('slide card under a selection', () => {
  const DOC =
    '\\documentclass{beamer}\n\nIntro.\n\\begin{frame}{Roadmap}\n  alpha\n  beta\n\\end{frame}\nOutro.';

  it('keeps the header, the body indent and the foot rendered', () => {
    const view = select(DOC, 'tex', at(DOC, 'Intro', 1), at(DOC, 'Outro', 2));
    expect(text(view)).not.toContain('\\begin{frame}');
    expect(text(view)).not.toContain('\\end{frame}');
    expect(text(view)).not.toContain('  alpha');
  });

  it('keeps the body indent hidden for a selection ending mid-row', () => {
    const view = select(DOC, 'tex', at(DOC, 'Intro', 1), at(DOC, 'alpha', 3));
    expect(text(view)).not.toContain('  alpha');
  });
});

describe('display math under a selection', () => {
  const MD = 'Intro paragraph.\n\n$$\nx^2 + y^2\n$$\n\nOutro paragraph.';
  const TEX = 'Intro paragraph.\n\n\\[ x^2 + y^2 \\]\n\nOutro paragraph.';

  it('stays rendered when the selection passes over the block (md)', () => {
    const view = select(MD, 'md', at(MD, 'Intro', 2), at(MD, 'Outro', 3));
    expect(text(view)).not.toContain('$$');
  });

  it('stays rendered when a drag ends on the block edge (md)', () => {
    // A pointer over the rendered equation resolves to the widget's edges.
    const view = select(MD, 'md', at(MD, 'Intro', 2), at(MD, '$$\n\nOutro') + 2);
    expect(text(view)).not.toContain('$$');
  });

  it('stays rendered when a drag ends on the block start (tex)', () => {
    const view = select(TEX, 'tex', at(TEX, 'Outro', 3), at(TEX, '\\['));
    expect(text(view)).not.toContain('\\[');
  });

  it('stays revealed when the selection starts inside the source (tex)', () => {
    const view = select(TEX, 'tex', at(TEX, 'x^2', 1), at(TEX, 'Outro', 3));
    expect(text(view)).toContain('\\[');
  });

  it('reveals when a selection end is stranded inside the block (md)', () => {
    const view = select(MD, 'md', at(MD, 'Intro', 2), at(MD, 'x^2', 1));
    expect(text(view)).toContain('$$');
  });
});
