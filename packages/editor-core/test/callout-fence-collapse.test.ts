import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * The collapsed closing fence must never occupy a visual row — REGARDLESS of
 * what the last body line is. Regression: a callout whose last body element is
 * a display-math block showed a phantom empty row where the `:::` (or
 * `\end{…}`) was: the fence-hiding replace merged the fence into the previous
 * line, but that line was entirely consumed by the math block widget, so the
 * merged residue rendered as an empty `.cm-line`. A text-ending callout
 * collapsed correctly, which is exactly the theorem-vs-proof inconsistency
 * reported from Welcome.md.
 */

const mount = (doc: string, language: Language): EditorView =>
  langView(doc, language, { ensureTree: true, cursor: 'end' });

afterEach(destroyViews);

/** The rendered rows: each direct child of .cm-content, labeled. */
function rows(view: EditorView): string[] {
  return Array.from(view.dom.querySelectorAll('.cm-content > *')).map((el) => {
    const cls = (el as HTMLElement).className.split(' ')[0] || el.tagName.toLowerCase();
    const text = (el.textContent ?? '').replace(/\s+/g, ' ').trim().slice(0, 24);
    return `${cls}:${text}`;
  });
}

/** Rows that are completely empty of text. */
function emptyLineRows(view: EditorView): string[] {
  return rows(view).filter((r) => r.startsWith('cm-line:') && r === 'cm-line:');
}

describe('md: collapsed closing fence occupies no row', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('text-ending callout: no empty row for the fence', () => {
    const view = mount('::: {#thm-a}\nSome statement.\n:::\nafter', 'md');
    // eslint-disable-next-line no-console
    console.log('[text-ending md]', JSON.stringify(rows(view)));
    expect(emptyLineRows(view)).toHaveLength(0);
    expect(view.dom.querySelector('.cm-content')!.textContent).not.toContain(':::');
  });

  it('math-ending callout: no phantom row between the widget and what follows', () => {
    const view = mount('::: {#thm-a}\nStatement.\n$$\nx+1\n$$\n:::\nafter', 'md');
    // eslint-disable-next-line no-console
    console.log('[math-ending md]', JSON.stringify(rows(view)));
    expect(view.dom.querySelector('.cm-math-display')).not.toBeNull();
    expect(emptyLineRows(view)).toHaveLength(0);
  });

  it('math-ending callout REVEALED: no phantom row under the preview widget', () => {
    // FINDINGS.md #2 (O-3): with the caret INSIDE the math, the revealed
    // block drops its preview widget at the math's end — exactly the
    // collapsed close fence's merge host — and the fence's newline-absorbing
    // hide rendered a stray empty row outside the box.
    const doc = '::: {#thm-a}\nStatement.\n$$\nx+1\n$$\n:::\nafter';
    const view = mount(doc, 'md');
    view.dispatch({ selection: { anchor: doc.indexOf('x+1') + 1 } });
    // eslint-disable-next-line no-console
    console.log('[math-ending md revealed]', JSON.stringify(rows(view)));
    expect(view.dom.querySelector('.cm-math-preview')).not.toBeNull();
    expect(emptyLineRows(view)).toHaveLength(0);
    // The fence stays collapsed (its hide kept the merge host).
    expect(view.dom.querySelector('.cm-content')!.textContent).not.toContain(':::');
  });

  it('math-ending and text-ending callouts collapse identically (no ::: text, no empties)', () => {
    const view = mount(
      [
        '::: {#thm-a}',
        'With math below.',
        '$$',
        'a^2',
        '$$',
        ':::',
        '',
        '::: {.proof}',
        'Just text.',
        ':::',
        'tail',
      ].join('\n'),
      'md',
    );
    // eslint-disable-next-line no-console
    console.log('[both md]', JSON.stringify(rows(view)));
    // The only intentionally-empty row is the blank separator line between the
    // two callouts (document line 7).
    expect(emptyLineRows(view)).toHaveLength(1);
    expect(view.dom.querySelector('.cm-content')!.textContent).not.toContain(':::');
  });
});

describe('tex: collapsed \\end fence occupies no row', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('text-ending environment: no empty row for the fence', () => {
    const view = mount('\\begin{theorem}\nSome statement.\n\\end{theorem}\nafter', 'tex');
    // eslint-disable-next-line no-console
    console.log('[text-ending tex]', JSON.stringify(rows(view)));
    expect(emptyLineRows(view)).toHaveLength(0);
    expect(view.dom.querySelector('.cm-content')!.textContent).not.toContain('\\end{theorem}');
  });

  it('math-ending environment: no phantom row', () => {
    const view = mount('\\begin{theorem}\nStatement.\n$$\nx+1\n$$\n\\end{theorem}\nafter', 'tex');
    // eslint-disable-next-line no-console
    console.log('[math-ending tex]', JSON.stringify(rows(view)));
    expect(view.dom.querySelector('.cm-tex-math-display')).not.toBeNull();
    expect(emptyLineRows(view)).toHaveLength(0);
  });

  it('math-ending environment REVEALED: no phantom row under the preview widget', () => {
    // FINDINGS.md #1 (O-3): the tex twin of the md case above.
    const doc = '\\begin{theorem}\nStatement.\n\\[\nE = mc^2\n\\]\n\\end{theorem}\nafter';
    const view = mount(doc, 'tex');
    view.dispatch({ selection: { anchor: doc.indexOf('mc^2') + 1 } });
    // eslint-disable-next-line no-console
    console.log('[math-ending tex revealed]', JSON.stringify(rows(view)));
    expect(view.dom.querySelector('.cm-tex-math-preview')).not.toBeNull();
    expect(emptyLineRows(view)).toHaveLength(0);
    expect(view.dom.querySelector('.cm-content')!.textContent).not.toContain('\\end{theorem}');
  });
});
