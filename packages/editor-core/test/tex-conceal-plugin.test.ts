import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

// ---------------------------------------------------------------------------
// LaTeX syntax concealment (mounted tex editor)
//
// The conceal plugin hides `\command{`/`}` syntax in preview mode and reveals
// the raw source when the caret is inside the construct. Marks (colors) come
// from texDecorationsPlugin and are not asserted here.
// ---------------------------------------------------------------------------

const mount = (docText: string, cursor: number, language: Language = 'tex'): EditorView =>
  langView(docText, language, { cursor });

afterEach(destroyViews);

const contentText = (view: EditorView) => view.dom.querySelector('.cm-content')!.textContent ?? '';
const widgetTexts = (view: EditorView, cls: string) =>
  Array.from(view.dom.querySelectorAll(`.${cls}`)).map((el) => el.textContent);

describe('inline formatting concealment', () => {
  const DOC = 'a \\emph{word} b';

  it('hides the command and braces when the caret is elsewhere', () => {
    const view = mount(DOC, DOC.length);
    const text = contentText(view);
    expect(text).not.toContain('\\emph{');
    expect(text).toContain('word');
    expect(text).not.toContain('}');
  });

  it('reveals the raw source when the caret is inside the construct', () => {
    const view = mount(DOC, DOC.indexOf('word') + 1);
    expect(contentText(view)).toContain('\\emph{word}');
  });

  it('caret on the backslash counts as inside', () => {
    const view = mount(DOC, DOC.indexOf('\\emph'));
    expect(contentText(view)).toContain('\\emph{word}');
  });

  it('caret just past the closing brace counts as outside', () => {
    const view = mount(DOC, DOC.indexOf('}') + 1);
    expect(contentText(view)).not.toContain('\\emph{');
  });

  it('a non-empty selection never reveals', () => {
    const view = mount(DOC, 0);
    view.dispatch({
      selection: EditorSelection.range(DOC.indexOf('word'), DOC.indexOf('word') + 3),
    });
    expect(contentText(view)).not.toContain('\\emph{');
  });

  it('keeps an empty argument raw so it stays visible', () => {
    const src = 'a \\emph{} b';
    const view = mount(src, 0);
    expect(contentText(view)).toContain('\\emph{}');
  });

  it('conceals nested commands independently', () => {
    const src = 'x \\textbf{\\emph{in}} y';
    const view = mount(src, 0);
    const text = contentText(view);
    expect(text).not.toContain('\\textbf');
    expect(text).not.toContain('\\emph');
    expect(text).toContain('in');
  });

  it('conceals the extra inline commands too', () => {
    const src = '\\underline{u} \\textsc{sc} \\texttt{tt}';
    const view = mount(src, src.length);
    const text = contentText(view);
    expect(text).not.toContain('\\underline{');
    expect(text).not.toContain('\\textsc{');
    expect(text).not.toContain('\\texttt{');
    expect(text).toContain('u');
    expect(text).toContain('sc');
    expect(text).toContain('tt');
  });
});

describe('sectioning concealment and numbering', () => {
  const DOC = '\\section{Alpha}\ntext\n\\subsection{Beta}\n\\section{Gamma}\nend';

  it('hides the sectioning commands when the caret is elsewhere', () => {
    const view = mount(DOC, DOC.length);
    const text = contentText(view);
    expect(text).not.toContain('\\section{');
    expect(text).not.toContain('\\subsection{');
    expect(text).toContain('Alpha');
    expect(text).toContain('Beta');
  });

  it('renders hierarchical section numbers', () => {
    const view = mount(DOC, DOC.length);
    expect(widgetTexts(view, 'cm-tex-secnum')).toEqual(['1', '1.1', '2']);
  });

  it('starred sections get no number', () => {
    const src = '\\section*{Plain}\nx';
    const view = mount(src, src.length);
    expect(contentText(view)).not.toContain('\\section*{');
    expect(contentText(view)).toContain('Plain');
    expect(widgetTexts(view, 'cm-tex-secnum')).toEqual([]);
  });

  it('starred sections do not advance the counters', () => {
    const src = '\\section{A}\n\\section*{Skip}\n\\section{B}\nx';
    const view = mount(src, src.length);
    expect(widgetTexts(view, 'cm-tex-secnum')).toEqual(['1', '2']);
  });

  it('caret on the heading reveals the raw command', () => {
    const view = mount(DOC, DOC.indexOf('Alpha') + 1);
    expect(contentText(view)).toContain('\\section{Alpha}');
    // The others stay concealed.
    expect(contentText(view)).not.toContain('\\subsection{');
  });

  it('conceals \\paragraph as run-in text without a number', () => {
    const src = '\\paragraph{Note} body';
    const view = mount(src, src.length);
    expect(contentText(view)).not.toContain('\\paragraph{');
    expect(contentText(view)).toContain('Note');
    expect(widgetTexts(view, 'cm-tex-secnum')).toEqual([]);
  });
});

describe('ref/cite/label pills', () => {
  it('renders \\ref as a key pill', () => {
    const src = 'see \\ref{fig:model} here';
    const view = mount(src, 0);
    expect(contentText(view)).not.toContain('\\ref{');
    expect(widgetTexts(view, 'cm-tex-ref-pill')).toEqual(['fig:model']);
  });

  it('renders \\cite keys as one pill, semicolon-separated', () => {
    const src = 'as in \\citep[p.~3]{smets2007, cee2005} x';
    const view = mount(src, 0);
    expect(contentText(view)).not.toContain('\\citep');
    expect(widgetTexts(view, 'cm-tex-ref-pill')).toEqual(['(smets2007; cee2005)']);
  });

  it('renders \\label as a dimmed pill', () => {
    const src = '\\label{sec:a} x';
    const view = mount(src, src.length);
    expect(contentText(view)).not.toContain('\\label{');
    expect(widgetTexts(view, 'cm-tex-label-pill')).toEqual(['sec:a']);
  });

  it('caret inside reveals the raw command', () => {
    const src = 'see \\ref{fig:model} here';
    const view = mount(src, 0);
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('fig:') + 2) });
    expect(contentText(view)).toContain('\\ref{fig:model}');
    expect(widgetTexts(view, 'cm-tex-ref-pill')).toEqual([]);
  });
});

describe('footnotes', () => {
  it('collapses \\footnote to a numbered superscript marker', () => {
    const src = 'claim\\footnote{first} and\\footnote{second} done';
    const view = mount(src, src.length);
    const text = contentText(view);
    expect(text).not.toContain('\\footnote');
    expect(text).not.toContain('first');
    expect(widgetTexts(view, 'cm-tex-footnote-mark')).toEqual(['1', '2']);
  });

  it('caret inside reveals the footnote text', () => {
    const src = 'claim\\footnote{first} end';
    const view = mount(src, src.indexOf('first'));
    expect(contentText(view)).toContain('\\footnote{first}');
  });

  it('a footnote argument spanning lines stays raw', () => {
    const src = 'claim\\footnote{one\ntwo} end';
    const view = mount(src, src.length);
    expect(contentText(view)).toContain('\\footnote{one');
  });

  it('commands inside a collapsed footnote do not leak decorations', () => {
    const src = 'x\\footnote{see \\emph{it}} y';
    const view = mount(src, src.length);
    const text = contentText(view);
    expect(text).not.toContain('it');
    expect(widgetTexts(view, 'cm-tex-footnote-mark')).toEqual(['1']);
  });
});

describe('links', () => {
  it('renders \\href as its display text with a data-url link mark', () => {
    const src = 'go \\href{https://x.y/z}{the site} now';
    const view = mount(src, 0);
    const text = contentText(view);
    expect(text).not.toContain('\\href');
    expect(text).not.toContain('https://x.y/z');
    expect(text).toContain('the site');
    const link = view.dom.querySelector('.cm-content .cm-live-link[data-url="https://x.y/z"]');
    expect(link).not.toBeNull();
    expect(link!.textContent).toBe('the site');
  });

  it('renders \\url showing the target as the link text', () => {
    const src = 'at \\url{https://x.y} end';
    const view = mount(src, 0);
    const text = contentText(view);
    expect(text).not.toContain('\\url{');
    expect(text).toContain('https://x.y');
    const link = view.dom.querySelector('.cm-content .cm-live-link[data-url="https://x.y"]');
    expect(link).not.toBeNull();
  });

  it('caret inside reveals the raw \\href', () => {
    const src = 'go \\href{https://x.y}{site} now';
    const view = mount(src, src.indexOf('site'));
    expect(contentText(view)).toContain('\\href{https://x.y}{site}');
  });
});

// ---------------------------------------------------------------------------
// Gesture-freeze: pointer-driven selection changes must not change geometry
// while the button is down; the reveal fires at release. A double-click within
// the undo window restores pre-reveal geometry before the word select.
// Keyboard/programmatic (untagged) selections stay instant — covered by every
// other test in this file.
// ---------------------------------------------------------------------------

function pointerSelect(view: EditorView, anchor: number, head?: number): void {
  view.dispatch({
    selection: head === undefined ? EditorSelection.cursor(anchor) : EditorSelection.range(anchor, head),
    userEvent: 'select.pointer',
  });
}

function press(view: EditorView, init: MouseEventInit = {}): void {
  view.contentDOM.dispatchEvent(
    new MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true, ...init }),
  );
}

function release(view: EditorView): void {
  view.contentDOM.ownerDocument.dispatchEvent(
    new MouseEvent('mouseup', { button: 0, bubbles: true }),
  );
}

describe('gesture-freeze on pointer selections', () => {
  const DOC = 'a \\emph{word} b\npark here';

  it('stays concealed while the button is down, reveals on release', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    press(view);
    pointerSelect(view, DOC.indexOf('word') + 1);
    expect(contentText(view)).not.toContain('\\emph{');
    release(view);
    expect(contentText(view)).toContain('\\emph{word}');
  });

  it('drag updates while pressed stay frozen; a non-empty release stays concealed', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    press(view);
    pointerSelect(view, DOC.indexOf('word'));
    pointerSelect(view, DOC.indexOf('word'), DOC.indexOf('word') + 2);
    pointerSelect(view, DOC.indexOf('word'), DOC.indexOf('word') + 4);
    expect(contentText(view)).not.toContain('\\emph{');
    release(view);
    expect(contentText(view)).not.toContain('\\emph{');
  });

  it('a doc change while frozen rebuilds immediately', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    const inWord = DOC.indexOf('word') + 1;
    press(view);
    pointerSelect(view, inWord);
    view.dispatch({ changes: { from: inWord, insert: 'x' } });
    expect(contentText(view)).toContain('\\emph{');
    release(view);
  });

  it('double-click after a release-reveal restores pre-reveal geometry', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    const inWord = DOC.indexOf('word') + 1;
    // Click 1: caret into the construct, reveal at release.
    press(view);
    pointerSelect(view, inWord);
    release(view);
    expect(contentText(view)).toContain('\\emph{word}');
    // Click 2 (detail 2) within the undo window: geometry snaps back BEFORE
    // CM6 would measure the click, and the word select keeps it concealed.
    press(view, { detail: 2 });
    expect(contentText(view)).not.toContain('\\emph{');
    pointerSelect(view, DOC.indexOf('word'), DOC.indexOf('word') + 4);
    release(view);
    expect(contentText(view)).not.toContain('\\emph{');
  });

  it('a later single click still reveals after an undo (override clears)', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    const inWord = DOC.indexOf('word') + 1;
    press(view);
    pointerSelect(view, inWord);
    release(view);
    press(view, { detail: 2 });
    pointerSelect(view, DOC.indexOf('word'), DOC.indexOf('word') + 4);
    release(view);
    // Fresh single click back into the construct.
    press(view);
    pointerSelect(view, inWord);
    release(view);
    expect(contentText(view)).toContain('\\emph{word}');
  });

  it('a bare pointer selection with no button down settles by itself', async () => {
    const view = mount(DOC, DOC.indexOf('park'));
    pointerSelect(view, DOC.indexOf('word') + 1);
    await Promise.resolve(); // straggler microtask
    expect(contentText(view)).toContain('\\emph{word}');
  });
});

describe('pill mousedown placement', () => {
  const DOC = 'see \\ref{fig:model} here\npark here';

  function pillMousedown(view: EditorView, extra: MouseEventInit = {}): void {
    const pill = view.dom.querySelector('.cm-tex-ref-pill')!;
    pill.dispatchEvent(
      new MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true, ...extra }),
    );
    // A real click always releases; the settle timer is gated on pointer-up.
    view.contentDOM.ownerDocument.dispatchEvent(
      new MouseEvent('mouseup', { button: 0, bubbles: true }),
    );
  }

  it('places the caret on the key and reveals on release', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    pillMousedown(view);
    expect(view.state.selection.main.head).toBe(DOC.indexOf('fig:model'));
    expect(view.state.selection.main.empty).toBe(true);
    // A pill click is an explicit "open this": reveal at mouseup, no settle.
    expect(contentText(view)).toContain('\\ref{fig:model}');
  });

  it('modified clicks (meta) are left to CodeMirror', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    const before = view.state.selection.main.head;
    pillMousedown(view, { metaKey: true });
    expect(view.state.selection.main.head).toBe(before);
  });
});

describe('inline math pointer behavior', () => {
  const DOC = 'text $x+y$ more\npark here';

  it('pointer selection into inline math stays rendered until release', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    press(view);
    pointerSelect(view, DOC.indexOf('x+y') + 1);
    expect(contentText(view)).not.toContain('$x+y$');
    release(view);
    expect(contentText(view)).toContain('$x+y$');
  });

  it('mousedown on the rendered formula places the caret and reveals on release', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    const widget = view.dom.querySelector('.cm-tex-math-inline')!;
    widget.dispatchEvent(
      new MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true }),
    );
    view.contentDOM.ownerDocument.dispatchEvent(
      new MouseEvent('mouseup', { button: 0, bubbles: true }),
    );
    expect(view.state.selection.main.head).toBe(DOC.indexOf('$x+y$'));
    expect(contentText(view)).toContain('$x+y$');
  });

  it('keyboard selection into inline math reveals instantly', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    view.dispatch({
      selection: EditorSelection.cursor(DOC.indexOf('x+y')),
      userEvent: 'select',
    });
    expect(contentText(view)).toContain('$x+y$');
  });
});

describe('source mode', () => {
  it('Cmd+: restores all raw syntax', () => {
    const src = '\\section{A}\n\\emph{x} \\ref{r:1}\nend';
    const view = mount(src, src.length);
    expect(contentText(view)).not.toContain('\\section{');
    view.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key: ':', ctrlKey: true, bubbles: true, cancelable: true }),
    );
    const text = contentText(view);
    expect(text).toContain('\\section{A}');
    expect(text).toContain('\\emph{x}');
    expect(text).toContain('\\ref{r:1}');
  });
});
