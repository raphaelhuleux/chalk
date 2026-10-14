import { describe, it, expect, afterEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * `cm-callout-bottom` must land on a line that still hosts a VISUAL row (S5).
 * When a callout's last body line is a fence the LIST plugin collapsed (e.g. a
 * theorem ending in an itemize, whose `\end{itemize}` merges into the last
 * `\item` line), a line decoration addressed to the collapsed line sits
 * mid-visual-line and CM6 silently drops it — the box then rendered with no
 * bottom edge. buildCalloutDecorations now walks the bottom class up past
 * list-collapsed lines via the `lineCollapsed` predicate setup.ts threads in.
 */

const mount = (doc: string, language: Language): EditorView =>
  langView(doc, language, { ensureTree: true, cursor: 'end' });

afterEach(destroyViews);

describe('tex: theorem ending in an itemize', () => {
  const DOC = [
    '\\begin{theorem}',
    'Statement.',
    '\\begin{itemize}',
    '\\item a',
    '\\item b',
    '\\end{itemize}',
    '\\end{theorem}',
    'after',
  ].join('\n');

  it('the visible bottom row (last \\item line) carries cm-callout-bottom', () => {
    const view = mount(DOC, 'tex');
    // Both the \end{itemize} and \end{theorem} lines are collapsed away.
    const content = view.dom.querySelector('.cm-content')!;
    expect(content.textContent).not.toContain('\\end{itemize}');
    expect(content.textContent).not.toContain('\\end{theorem}');

    const bottoms = Array.from(content.querySelectorAll('.cm-line.cm-callout-bottom'));
    expect(bottoms).toHaveLength(1);
    // The last visible box row is the second \item line ('b').
    expect(bottoms[0].textContent).toContain('b');
  });

  it('revealing the list close fence moves the bottom class onto it', () => {
    const view = mount(DOC, 'tex');
    const fence = view.state.doc.line(6); // \end{itemize}
    view.dispatch({ selection: { anchor: fence.from } });
    const content = view.dom.querySelector('.cm-content')!;
    expect(content.textContent).toContain('\\end{itemize}'); // revealed, hosts a row
    const bottoms = Array.from(content.querySelectorAll('.cm-line.cm-callout-bottom'));
    expect(bottoms).toHaveLength(1);
    expect(bottoms[0].textContent).toContain('\\end{itemize}');
  });
});
