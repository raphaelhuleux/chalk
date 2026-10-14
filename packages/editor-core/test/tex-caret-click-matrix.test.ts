import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { destroyViews, langView } from './helpers/views';

/**
 * Regression matrix for caret navigation and pointer interaction over
 * previewed LaTeX constructs — the contracts behind the 2026-08-12 click and
 * vertical-motion fixes. Each test pins one behavior a user relies on:
 *
 *   - Left/Right ENTER constructs (reveal on entry) — deliberate navigation.
 *   - Up/Down pass OVER widget-rendered constructs (no reveal in transit).
 *   - Clicks on pills/widgets place the caret ON the editable content.
 *   - Mouse gestures never change geometry mid-press (freeze), and modified
 *     clicks (shift/meta/ctrl) stay CM6's business.
 *
 * Geometric behavior (wrapped rows, pixel goal columns, click coordinates)
 * is NOT testable in jsdom — Tests/browser/run.mjs
 * covers those against the built bundle in a real browser.
 */

const mount = (doc: string, cursor: number, language: Language = 'tex'): EditorView =>
  langView(doc, language, { cursor });

afterEach(destroyViews);

const contentText = (v: EditorView) => v.dom.querySelector('.cm-content')!.textContent ?? '';
const head = (v: EditorView) => v.state.selection.main.head;

function press(view: EditorView, key: string, init: KeyboardEventInit = {}): void {
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init }),
  );
}

function mousedown(el: Element, init: MouseEventInit = {}): void {
  el.dispatchEvent(new MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true, ...init }));
}

function mouseup(view: EditorView): void {
  view.contentDOM.ownerDocument.dispatchEvent(new MouseEvent('mouseup', { button: 0, bubbles: true }));
}

// ---------------------------------------------------------------------------
// Horizontal navigation: Left/Right deliberately ENTER constructs
// ---------------------------------------------------------------------------

describe('horizontal arrow entry (reveals are deliberate)', () => {
  it('ArrowRight from just outside \\emph steps in and reveals', () => {
    const doc = 'a \\emph{word} b';
    const view = mount(doc, doc.indexOf('\\emph') - 1);
    press(view, 'ArrowRight');
    expect(contentText(view)).toContain('\\emph{word}');
  });

  it('ArrowRight from just before a pill steps in and reveals', () => {
    const doc = 'see \\ref{fig:model} here';
    const view = mount(doc, doc.indexOf('\\ref') - 1);
    press(view, 'ArrowRight');
    expect(contentText(view)).toContain('\\ref{fig:model}');
  });

  it('ArrowLeft out of a revealed construct conceals it again', () => {
    const doc = 'a \\emph{word} b';
    const view = mount(doc, doc.indexOf('\\emph')); // inside → revealed
    expect(contentText(view)).toContain('\\emph{');
    press(view, 'ArrowLeft'); // to cmdFrom-1: outside
    expect(contentText(view)).not.toContain('\\emph{');
  });
});

// ---------------------------------------------------------------------------
// Vertical navigation: Up/Down pass OVER rendered constructs
// ---------------------------------------------------------------------------

describe('vertical transit over rendered constructs', () => {
  it('ArrowDown never parks inside a concealed ref pill', () => {
    const doc = 'aaaaaaaaaaaaaaa\naa \\ref{fig:model} b\nccccccccccccccc';
    const view = mount(doc, 8); // column lands mid-pill on line 2
    press(view, 'ArrowDown');
    const cmdFrom = doc.indexOf('\\ref');
    const end = doc.indexOf('}') + 1;
    expect(head(view) >= cmdFrom && head(view) < end).toBe(false);
    expect(contentText(view)).not.toContain('\\ref{');
  });

  it('Shift+ArrowDown (selection extension) is not hijacked by the snap keymap', () => {
    const doc = 'aaaa aaaa\naa $x+y$ bb\ncccc cccc';
    const view = mount(doc, 3);
    press(view, 'ArrowDown', { shiftKey: true });
    expect(view.state.selection.main.empty).toBe(false);
    expect(view.state.selection.main.anchor).toBe(3);
  });

  it('source mode shows raw text and vertical motion still moves (snap gated off)', () => {
    // jsdom's layoutless vertical fallback can't pin WHERE the caret lands;
    // the browser harness asserts a source-mode landing INSIDE raw math.
    const doc = 'aaaa aaaa\naa $x+y$ bb\ncccc cccc';
    const view = mount(doc, 5);
    // Mod-: cycles preview → mixed → source; two presses reach source.
    press(view, ':', { ctrlKey: true });
    press(view, ':', { ctrlKey: true });
    expect(contentText(view)).toContain('$x+y$');
    press(view, 'ArrowDown');
    expect(view.state.doc.lineAt(head(view)).number).toBeGreaterThan(1);
  });
});

// ---------------------------------------------------------------------------
// Clicks on previewed widgets: caret lands ON the editable content
// ---------------------------------------------------------------------------

describe('widget clicks place the caret on the content', () => {
  it('cite pill → caret at the first key', () => {
    const doc = 'as in \\citep[p.~3]{smets2007, cee2005} x\npark';
    const view = mount(doc, doc.indexOf('park'));
    mousedown(view.dom.querySelector('.cm-tex-ref-pill')!);
    mouseup(view);
    expect(head(view)).toBe(doc.indexOf('smets2007'));
    expect(contentText(view)).toContain('\\citep');
  });

  it('label pill → caret at the key', () => {
    const doc = '\\label{sec:a} x\npark';
    const view = mount(doc, doc.indexOf('park'));
    mousedown(view.dom.querySelector('.cm-tex-label-pill')!);
    mouseup(view);
    expect(head(view)).toBe(doc.indexOf('sec:a'));
    expect(contentText(view)).toContain('\\label{sec:a}');
  });

  it('footnote marker → caret at the note text', () => {
    const doc = 'claim\\footnote{first} end\npark';
    const view = mount(doc, doc.indexOf('park'));
    mousedown(view.dom.querySelector('.cm-tex-footnote-mark')!);
    mouseup(view);
    expect(head(view)).toBe(doc.indexOf('first'));
    expect(contentText(view)).toContain('\\footnote{first}');
  });

  it('ctrl-click on a pill is left to CodeMirror (context menu path)', () => {
    const doc = 'see \\ref{fig:model} here\npark';
    const view = mount(doc, doc.indexOf('park'));
    const before = head(view);
    mousedown(view.dom.querySelector('.cm-tex-ref-pill')!, { ctrlKey: true });
    mouseup(view);
    expect(head(view)).toBe(before);
  });

  it('a press inside a selection that covers the pill defers to CM6 (drag semantics)', () => {
    const doc = 'see \\ref{fig:model} here';
    const view = mount(doc, 0);
    view.dispatch({
      selection: EditorSelection.range(doc.indexOf('see'), doc.indexOf('here')),
    });
    mousedown(view.dom.querySelector('.cm-tex-ref-pill')!);
    mouseup(view);
    // The pill handler declined — the caret was NOT parked on the key (what
    // CM6's own builtin then does with the press is its business; jsdom's
    // coordinate-less fallback makes that part unassertable here).
    expect(head(view)).not.toBe(doc.indexOf('fig:model'));
  });
});

// ---------------------------------------------------------------------------
// Gesture edges: freeze scope and double-click-undo arming
// ---------------------------------------------------------------------------

describe('gesture-freeze edges', () => {
  const DOC = 'a \\emph{word} b\npark here';

  it('keyboard motion during a frozen press rebuilds instantly', () => {
    const view = mount(DOC, DOC.indexOf('park'));
    view.contentDOM.dispatchEvent(
      new MouseEvent('mousedown', { button: 0, bubbles: true, cancelable: true }),
    );
    view.dispatch({
      selection: EditorSelection.cursor(DOC.indexOf('word') + 2),
      userEvent: 'select.pointer',
    });
    expect(contentText(view)).not.toContain('\\emph{'); // frozen
    press(view, 'ArrowLeft'); // keyboard ends the gesture semantics
    expect(contentText(view)).toContain('\\emph{word}');
    mouseup(view);
  });

  it('a pill-opened reveal does not arm the double-click undo', () => {
    const doc = 'see \\ref{fig:model} here\npark';
    const view = mount(doc, doc.indexOf('park'));
    mousedown(view.dom.querySelector('.cm-tex-ref-pill')!);
    mouseup(view);
    expect(contentText(view)).toContain('\\ref{fig:model}'); // opened
    // A rapid second click (detail 2) must NOT snap the pill closed — the
    // reveal was the point of the click.
    view.contentDOM.dispatchEvent(
      new MouseEvent('mousedown', { button: 0, detail: 2, bubbles: true, cancelable: true }),
    );
    expect(contentText(view)).toContain('\\ref{fig:model}');
    mouseup(view);
  });
});
