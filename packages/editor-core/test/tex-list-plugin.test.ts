import { describe, it, expect, afterEach } from 'vitest';
import { Text, EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import {
  scanTexListRegions,
  enumerateLabel,
  itemizeLabel,
  parseListOptions,
  texListLineDepths,
} from '../src/editor/tex-list-plugin';
import { destroyViews, langView } from './helpers/views';

/**
 * enumerate/itemize live rendering: lone \begin/\end fence lines collapse,
 * line-leading \item tokens render as LaTeX-default markers (1. / (a) / i. /
 * A., • / – / ∗ / ·) or the labels the list options set, caret reveals raw
 * source. Limits: options we can't reproduce keep the fence raw,
 * \item[custom] keeps the bracket visible, an env with no items stays fully
 * revealed.
 */

const doc = (...lines: string[]) => Text.of(lines);

// ---------------------------------------------------------------------------
// Scanner + labels (pure)
// ---------------------------------------------------------------------------

describe('scanTexListRegions', () => {
  it('flat enumerate: one region, arabic labels in order', () => {
    const regions = scanTexListRegions(
      doc('\\begin{enumerate}', '\\item a', '\\item b', '\\item c', '\\end{enumerate}'),
    );
    expect(regions).toHaveLength(1);
    const [r] = regions;
    expect(r.kind).toBe('enumerate');
    expect(r.depth).toBe(1);
    expect(r.openLine).toBe(1);
    expect(r.closeLine).toBe(5);
    expect(r.items.map((i) => i.label)).toEqual(['1.', '2.', '3.']);
    expect(r.items.map((i) => i.line)).toEqual([2, 3, 4]);
  });

  it('nested enumerate follows the LaTeX label sequence per depth', () => {
    const regions = scanTexListRegions(
      doc(
        '\\begin{enumerate}',
        '\\item outer one',
        '  \\begin{enumerate}',
        '  \\item inner one',
        '    \\begin{enumerate}',
        '    \\item deep one',
        '    \\item deep two',
        '    \\end{enumerate}',
        '  \\item inner two',
        '  \\end{enumerate}',
        '\\item outer two',
        '\\end{enumerate}',
      ),
    );
    // Regions close inner-first.
    expect(regions.map((r) => r.depth)).toEqual([3, 2, 1]);
    expect(regions[0].items.map((i) => i.label)).toEqual(['i.', 'ii.']);
    expect(regions[1].items.map((i) => i.label)).toEqual(['(a)', '(b)']);
    // The outer count continues across the nested env.
    expect(regions[2].items.map((i) => i.label)).toEqual(['1.', '2.']);
  });

  it('itemize depth counts only itemize ancestors; mixed nesting stays per-kind', () => {
    const regions = scanTexListRegions(
      doc(
        '\\begin{enumerate}',
        '\\item top',
        '  \\begin{itemize}',
        '  \\item bullet',
        '    \\begin{enumerate}',
        '    \\item nested enum',
        '    \\end{enumerate}',
        '  \\end{itemize}',
        '\\end{enumerate}',
      ),
    );
    const itemize = regions.find((r) => r.kind === 'itemize')!;
    expect(itemize.depth).toBe(1);
    expect(itemize.items[0].label).toBe('•');
    // enumerate > itemize > enumerate: the inner enumerate is enumerate-depth 2.
    const innerEnum = regions.find((r) => r.kind === 'enumerate' && r.openLine === 5)!;
    expect(innerEnum.depth).toBe(2);
    expect(innerEnum.items[0].label).toBe('(a)');
  });

  it('honors an enumitem label: the fence can collapse and items use it', () => {
    const [r] = scanTexListRegions(
      doc('\\begin{enumerate}[label=(\\alph*)]', '\\item a', '\\item b', '\\end{enumerate}'),
    );
    expect(r.openStaysRaw).toBe(false);
    expect(r.items.map((i) => i.label)).toEqual(['(a)', '(b)']);
  });

  it('options it cannot reproduce keep the fence raw and the default labels', () => {
    const [r] = scanTexListRegions(
      doc('\\begin{enumerate}[resume]', '\\item a', '\\end{enumerate}'),
    );
    expect(r.openStaysRaw).toBe(true);
    expect(r.items[0].label).toBe('1.');
  });

  it('unclosed env yields no region; mismatched \\end is body text', () => {
    expect(scanTexListRegions(doc('\\begin{enumerate}', '\\item a'))).toHaveLength(0);
    // \end{itemize} can't close the open enumerate — the env stays open to EOF.
    expect(
      scanTexListRegions(doc('\\begin{enumerate}', '\\item a', '\\end{itemize}')),
    ).toHaveLength(0);
  });

  it('\\item token excludes a [custom] bracket and longer commands', () => {
    const d = doc('\\begin{itemize}', '  \\item[K] term', '  \\itemsep is not an item', '\\end{itemize}');
    const [r] = scanTexListRegions(d);
    expect(r.items).toHaveLength(1);
    const item = r.items[0];
    expect(item.from).toBe(d.line(2).from + 2); // after the 2-space indent
    // Token is exactly `\item` — the `[K]` stays outside (visible raw).
    expect(item.to - item.from).toBe('\\item'.length);
  });

  it('\\item outside any list env is ignored', () => {
    expect(scanTexListRegions(doc('\\item stray'))).toHaveLength(0);
  });
});

describe('parseListOptions', () => {
  const labels = (kind: 'enumerate' | 'itemize', args: string, n = 3) => {
    const o = parseListOptions(kind, args);
    return o && Array.from({ length: n }, (_, i) => (o.label ? o.label(i + o.start) : null));
  };

  it('enumitem counters, with surrounding text and formatting', () => {
    expect(labels('enumerate', 'label=(\\roman*)')).toEqual(['(i)', '(ii)', '(iii)']);
    expect(labels('enumerate', 'label=\\Alph*.')).toEqual(['A.', 'B.', 'C.']);
    expect(labels('enumerate', 'label=\\textbf{\\arabic*)}')).toEqual(['1)', '2)', '3)']);
    expect(labels('enumerate', 'label={Step \\arabic*:}')).toEqual(['Step 1:', 'Step 2:', 'Step 3:']);
  });

  it('start= offsets the count', () => {
    expect(labels('enumerate', 'label=\\arabic*., start=4', 2)).toEqual(['4.', '5.']);
  });

  it("the enumerate package's shorthand", () => {
    expect(labels('enumerate', '(i)')).toEqual(['(i)', '(ii)', '(iii)']);
    expect(labels('enumerate', 'a)', 2)).toEqual(['a)', 'b)']);
    expect(labels('enumerate', 'I.', 2)).toEqual(['I.', 'II.']);
  });

  it('itemize bullets', () => {
    expect(labels('itemize', 'label=--', 1)).toEqual(['–']);
    expect(labels('itemize', 'label=$\\bullet$', 1)).toEqual(['•']);
    expect(labels('itemize', 'label=\\textbullet', 1)).toEqual(['•']);
  });

  it('spacing-only options keep the default labels', () => {
    expect(parseListOptions('enumerate', 'noitemsep')).toEqual({ label: null, start: 1 });
    expect(parseListOptions('itemize', 'leftmargin=*, itemsep=2pt')).toEqual({ label: null, start: 1 });
  });

  it('null when the labels would come out wrong', () => {
    expect(parseListOptions('enumerate', 'resume')).toBeNull();
    expect(parseListOptions('enumerate', 'label=\\arabic*.\\arabic*')).toBeNull();
    expect(parseListOptions('enumerate', 'label=\\ding{172}')).toBeNull();
    expect(parseListOptions('itemize', 'label=\\ding{43}')).toBeNull();
  });
});

describe('texListLineDepths', () => {
  it('counts every enclosing list, whatever its kind; fences count for the parent', () => {
    const depths = texListLineDepths(
      doc(
        '\\begin{enumerate}', //       1
        '\\item a', //                 2
        '\\begin{itemize}', //         3 (parent body)
        '\\item b', //                 4
        'continuation', //              5
        '\\end{itemize}', //           6 (parent body)
        '\\end{enumerate}', //         7
        'after', //                     8
      ),
    );
    expect([...depths.entries()].sort((a, b) => a[0] - b[0])).toEqual([
      [2, 1],
      [3, 1],
      [4, 2],
      [5, 2],
      [6, 1],
    ]);
  });

  it('an env with no items adds no depth', () => {
    expect(texListLineDepths(doc('\\begin{itemize}', 'x', '\\end{itemize}')).size).toBe(0);
  });
});

describe('verbatim environments are opaque to the scanner (H-8)', () => {
  it('itemize inside verbatim stays raw', () => {
    expect(
      scanTexListRegions(
        doc(
          '\\begin{verbatim}',
          '\\begin{itemize}',
          '\\item a',
          '\\end{itemize}',
          '\\end{verbatim}',
        ),
      ),
    ).toHaveLength(0);
  });

  it('lstlisting and minted (with args) are opaque too', () => {
    expect(
      scanTexListRegions(
        doc(
          '\\begin{lstlisting}[language=TeX]',
          '\\begin{enumerate}',
          '\\item a',
          '\\end{enumerate}',
          '\\end{lstlisting}',
        ),
      ),
    ).toHaveLength(0);
    expect(
      scanTexListRegions(
        doc(
          '\\begin{minted}{latex}',
          '\\begin{itemize}',
          '\\item a',
          '\\end{itemize}',
          '\\end{minted}',
        ),
      ),
    ).toHaveLength(0);
  });

  it('a \\begin inside verbatim does not pair with an \\end outside it', () => {
    expect(
      scanTexListRegions(
        doc(
          '\\begin{verbatim}',
          '\\begin{itemize}',
          '\\end{verbatim}',
          '\\item a',
          '\\end{itemize}',
        ),
      ),
    ).toHaveLength(0);
  });

  it('only the MATCHING \\end exits the verbatim body', () => {
    // \end{lstlisting} inside a verbatim body is literal text; the itemize
    // after it is still inside verbatim and must stay raw.
    expect(
      scanTexListRegions(
        doc(
          '\\begin{verbatim}',
          '\\end{lstlisting}',
          '\\begin{itemize}',
          '\\item a',
          '\\end{itemize}',
          '\\end{verbatim}',
        ),
      ),
    ).toHaveLength(0);
  });

  it('a list after a closed verbatim still renders', () => {
    const regions = scanTexListRegions(
      doc(
        '\\begin{verbatim}',
        'code',
        '\\end{verbatim}',
        '\\begin{itemize}',
        '\\item a',
        '\\end{itemize}',
      ),
    );
    expect(regions).toHaveLength(1);
    expect(regions[0]).toMatchObject({ kind: 'itemize', openLine: 4, closeLine: 6 });
  });
});

describe('label sequences', () => {
  it('enumerate: 1. → (a) → i. → A., with bijective letters past z', () => {
    expect(enumerateLabel(1, 2)).toBe('2.');
    expect(enumerateLabel(2, 1)).toBe('(a)');
    expect(enumerateLabel(2, 27)).toBe('(aa)');
    expect(enumerateLabel(3, 4)).toBe('iv.');
    expect(enumerateLabel(4, 2)).toBe('B.');
    expect(enumerateLabel(9, 1)).toBe('A.'); // clamped past depth 4
  });

  it('itemize: • – ∗ ·, clamped', () => {
    expect([1, 2, 3, 4, 5].map(itemizeLabel)).toEqual(['•', '–', '∗', '·', '·']);
  });
});

// ---------------------------------------------------------------------------
// DOM rendering + reveal (mounted tex editor)
// ---------------------------------------------------------------------------

const mount = (docText: string, cursor: number, language: Language = 'tex'): EditorView =>
  langView(docText, language, { cursor });

afterEach(destroyViews);

const contentText = (view: EditorView) => view.dom.querySelector('.cm-content')!.textContent ?? '';
const markers = (view: EditorView) =>
  Array.from(view.dom.querySelectorAll('.cm-tex-item-marker')).map((el) => el.textContent);

/** Dispatch a real keydown so the full Prec.high keymap chain runs. */
function press(view: EditorView, key: string): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }),
  );
}

const LIST = 'intro\n\\begin{enumerate}\n\\item a\n\\item b\n\\end{enumerate}\nafter';

describe('tex list rendering', () => {
  it('collapses both fences and renders numbered markers (caret elsewhere)', () => {
    const view = mount(LIST, LIST.length);
    const text = contentText(view);
    expect(text).not.toContain('\\begin{enumerate}');
    expect(text).not.toContain('\\end{enumerate}');
    expect(text).not.toContain('\\item');
    expect(markers(view)).toEqual(['1.', '2.']);
  });

  it('doc-leading fence (line 1) collapses too', () => {
    const view = mount('\\begin{itemize}\n\\item x\n\\end{itemize}\ntail', 'x'.length + 30);
    const text = contentText(view);
    expect(text).not.toContain('\\begin{itemize}');
    expect(markers(view)).toEqual(['•']);
  });

  it('caret on a fence line reveals that fence', () => {
    const view = mount(LIST, 0);
    view.dispatch({ selection: EditorSelection.cursor(LIST.indexOf('\\begin') + 3) });
    expect(contentText(view)).toContain('\\begin{enumerate}');
    expect(contentText(view)).not.toContain('\\end{enumerate}');
  });

  it('caret inside the \\item token reveals that item only', () => {
    const view = mount(LIST, 0);
    view.dispatch({ selection: EditorSelection.cursor(LIST.indexOf('\\item b') + 2) });
    expect(contentText(view)).toContain('\\item b');
    expect(markers(view)).toEqual(['1.']); // item a still rendered
  });

  it('caret just past the token (start of item text) keeps the marker', () => {
    const view = mount(LIST, LIST.indexOf('\\item a') + '\\item '.length);
    expect(markers(view)).toEqual(['1.', '2.']);
  });

  it('honored list options collapse the open fence and set the markers', () => {
    const src = '\\begin{enumerate}[label=(\\alph*)]\n\\item a\n\\end{enumerate}\ntail';
    const view = mount(src, src.length);
    expect(contentText(view)).not.toContain('[label=(\\alph*)]');
    expect(markers(view)).toEqual(['(a)']);
  });

  it('options it cannot reproduce keep the open fence raw and dimmed', () => {
    const src = 'x\n\\begin{enumerate}[resume]\n\\item a\n\\end{enumerate}\ntail';
    const view = mount(src, src.length);
    const dim = Array.from(view.dom.querySelectorAll('.cm-syntax-dim')).map((el) => el.textContent);
    expect(dim).toContain('\\begin{enumerate}[resume]');
    expect(markers(view)).toEqual(['1.']);
  });

  it('\\item[custom] renders the marker and keeps the bracket visible', () => {
    const src = '\\begin{itemize}\n\\item[K] term\n\\end{itemize}\ntail';
    const view = mount(src, src.length);
    expect(markers(view)).toEqual(['•']);
    expect(contentText(view)).toContain('[K] term');
  });

  it('an env with no items stays fully revealed', () => {
    const src = 'a\n\\begin{enumerate}\n\\end{enumerate}\nb';
    const view = mount(src, 0);
    expect(contentText(view)).toContain('\\begin{enumerate}');
    expect(contentText(view)).toContain('\\end{enumerate}');
  });

  it('list inside a theorem callout: both render together', () => {
    const src =
      '\\begin{theorem}\n\\begin{enumerate}\n\\item a\n\\item b\n\\end{enumerate}\n\\end{theorem}\ntail';
    const view = mount(src, src.length);
    const text = contentText(view);
    expect(text).toContain('Theorem 1'); // callout label widget
    expect(markers(view)).toEqual(['1.', '2.']);
    expect(text).not.toContain('\\begin{enumerate}');
    expect(text).not.toContain('\\item');
  });

  // Math-ending lists: the math widget absorbs the following collapsed fence
  // line(s) (listFenceHideThrough), the same mechanism as calloutBlockAt's
  // hideTo — a fence merge-hosted on a widget-consumed line would otherwise
  // render a phantom empty row.
  const emptyLineRows = (view: EditorView) =>
    Array.from(view.dom.querySelectorAll('.cm-content > .cm-line')).filter(
      (el) => (el.textContent ?? '') === '',
    );

  it('display math directly before \\end: fence absorbed, no phantom row', () => {
    const src = '\\begin{itemize}\n\\item math:\n\\[\nx^2\n\\]\n\\end{itemize}\ntail';
    const view = mount(src, src.length);
    expect(markers(view)).toEqual(['•']);
    expect(contentText(view)).not.toContain('\\end{itemize}');
    expect(emptyLineRows(view)).toHaveLength(0);
  });

  it('math ending a nested itemize absorbs BOTH stacked close fences', () => {
    const src =
      '\\begin{enumerate}\n\\item outer\n\\begin{itemize}\n\\item inner\n\\[\nx^2\n\\]\n\\end{itemize}\n\\end{enumerate}\ntail';
    const view = mount(src, src.length);
    const text = contentText(view);
    expect(text).not.toContain('\\end{itemize}');
    expect(text).not.toContain('\\end{enumerate}');
    expect(emptyLineRows(view)).toHaveLength(0);
  });

  it('list fence stays revealed when a collapsed callout close follows it directly', () => {
    const src =
      '\\begin{theorem}\n\\begin{itemize}\n\\item math:\n\\[\nx^2\n\\]\n\\end{itemize}\n\\end{theorem}\ntail';
    const view = mount(src, src.length);
    // The math widget must NOT absorb \end{itemize}: \end{theorem}'s merge
    // host would sit inside the widget replace, bringing the phantom row back.
    expect(contentText(view)).toContain('\\end{itemize}');
    expect(contentText(view)).not.toContain('\\end{theorem}');
    expect(emptyLineRows(view)).toHaveLength(0);
  });

  it('blank line between list fence and callout close: everything collapses', () => {
    const src =
      '\\begin{proposition}\n\\begin{enumerate}\n\\item eq:\n\\begin{equation}\nx^2\n\\end{equation}\n\\end{enumerate}\n\n\\end{proposition}\ntail';
    const view = mount(src, src.length);
    const text = contentText(view);
    expect(text).not.toContain('\\end{enumerate}');
    expect(text).not.toContain('\\end{proposition}');
    expect(markers(view)).toEqual(['1.']);
  });
});

describe('preview lays lists out from structure', () => {
  const NESTED = [
    'intro',
    '\\begin{enumerate}',
    '    \\item a',
    '    continued',
    '    \\begin{itemize}',
    '        \\item b',
    '    \\end{itemize}',
    '\\end{enumerate}',
    'tail',
  ].join('\n');
  const listLines = (view: EditorView) =>
    Array.from(view.dom.querySelectorAll<HTMLElement>('.cm-tex-list-line')).map((el) => ({
      text: el.textContent,
      hang: /--chalk-hang:\s*([^;]+)/.exec(el.getAttribute('style') ?? '')?.[1],
      item: el.classList.contains('cm-tex-list-item'),
    }));

  it('each body line hangs by its depth in em, with source indentation hidden', () => {
    const view = mount(NESTED, NESTED.length);
    expect(listLines(view)).toEqual([
      { text: '1.a', hang: '2.5em', item: true },
      { text: 'continued', hang: '2.5em', item: false },
      { text: '•b', hang: '4.7em', item: true },
    ]);
  });

  it('hanging-indent.ts stands down on those lines (no ch hang)', () => {
    const view = mount(NESTED, NESTED.length);
    for (const el of view.dom.querySelectorAll('.cm-tex-list-line')) {
      expect(el.getAttribute('style')).not.toMatch(/\dch/);
    }
  });

  it('caret on \\item opens the raw token inside the hang', () => {
    const view = mount(NESTED, NESTED.indexOf('\\item a') + 2);
    const revealed = view.dom.querySelector('.cm-tex-item-revealed');
    expect(revealed?.textContent).toBe('\\item ');
  });

  it('mixed keeps the source layout', () => {
    const view = langView(NESTED, 'tex', { viewMode: 'mixed', cursor: NESTED.length });
    expect(view.dom.querySelector('.cm-tex-list-line')).toBeNull();
    expect(contentText(view)).toContain('    \\item a');
  });

  it('display math in an item is indented with it', () => {
    const src = 'x\n\\begin{itemize}\n\\item a\n\\[\nx^2\n\\]\n\\end{itemize}\ntail';
    const view = mount(src, src.length);
    const indent = view.dom.querySelector<HTMLElement>('.cm-tex-math-list-indent');
    expect(indent?.style.paddingLeft).toBe('2.5em');
  });
});

describe('fence-stop keymap', () => {
  const line = (view: EditorView, n: number) => view.state.doc.line(n);
  const head = (view: EditorView) => view.state.selection.main.head;

  // 1 intro, 2 open, 3-4 items, 5 close, 6 after.
  it('ArrowDown from above stops on the collapsed open fence and reveals it', () => {
    const view = mount(LIST, 2); // on 'intro'
    press(view, 'ArrowDown');
    expect(line(view, 2).from <= head(view) && head(view) <= line(view, 2).to).toBe(true);
    expect(contentText(view)).toContain('\\begin{enumerate}');
  });

  it('ArrowUp from below stops on the collapsed close fence and reveals it', () => {
    const view = mount(LIST, LIST.indexOf('after') + 2);
    press(view, 'ArrowUp');
    expect(line(view, 5).from <= head(view) && head(view) <= line(view, 5).to).toBe(true);
    expect(contentText(view)).toContain('\\end{enumerate}');
  });

  // Continuing OFF the fence onto an item line is a declined key that falls
  // through to CM6's geometric default motion — jsdom can't measure that (see
  // caret-callout-navigation.test.ts); covered by the browser harness instead.
});
