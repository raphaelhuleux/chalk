import { describe, it, expect, afterEach } from 'vitest';
import { EditorView } from '@codemirror/view';
import { destroyViews, langView, mdView } from './helpers/views';

/**
 * French (AZERTY) dead key on Mac Catalyst: `a` `^` `2` must leave `a^2`.
 *
 * WebKit inside the Catalyst web view inserts TWICE for the one `2` press —
 * the committed dead key, then the key's own characters, which repeat it
 * (trace captured in the real WKWebView, owner report 2026-09-11):
 *
 *   keydown key=^2 code=Digit2
 *   beforeinput/input inputType=deleteCompositionText   (marked ^ removed)
 *   compositionend data=""
 *   textInput data=^  → beforeinput/input insertText data=^   → doc a^
 *   textInput data=^2 → beforeinput/input insertText data=^2  → doc a^^2
 *
 * See src/editor/dead-key-commit.ts.
 */

afterEach(() => destroyViews());

/** Open and commit a dead-key composition of `composed` on `view`. */
function compose(view: EditorView, composed: string): void {
  const dom = view.contentDOM;
  dom.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }));
  dom.dispatchEvent(new CompositionEvent('compositionupdate', { data: composed, bubbles: true }));
  // WebKit's compositionend for a dead key carries no data; the composed text
  // is what compositionupdate last reported.
  dom.dispatchEvent(new CompositionEvent('compositionend', { data: '', bubbles: true }));
}

/** Dispatch one `beforeinput` insertText and report whether it was cancelled.
 *  jsdom inserts nothing by itself, so an uncancelled event is followed by the
 *  insert the browser would have made. A cancelled one is followed by a
 *  microtask turn: the guard queues its replacement dispatch rather than
 *  running it inline, so it lands behind CodeMirror's own DOM flush. */
async function insertText(view: EditorView, data: string): Promise<boolean> {
  const ev = new InputEvent('beforeinput', {
    inputType: 'insertText',
    data,
    cancelable: true,
    bubbles: true,
  });
  view.contentDOM.dispatchEvent(ev);
  if (ev.defaultPrevented) await Promise.resolve();
  else view.dispatch(view.state.replaceSelection(data));
  return ev.defaultPrevented;
}

describe('dead-key commit dedupe', () => {
  it('drops the repeated commit from the second insert of one key press', async () => {
    const view = mdView('a', { cursor: 1, deadKeyCommitDedupe: true });
    compose(view, '^');
    expect(await insertText(view, '^')).toBe(false);
    expect(view.state.doc.toString()).toBe('a^');
    expect(await insertText(view, '^2')).toBe(true);
    expect(view.state.doc.toString()).toBe('a^2');
  });

  it('does nothing when the option is off', async () => {
    const view = mdView('a', { cursor: 1 });
    compose(view, '^');
    expect(await insertText(view, '^')).toBe(false);
    expect(await insertText(view, '^2')).toBe(false);
    expect(view.state.doc.toString()).toBe('a^^2');
  });

  it('leaves a composable commit alone', async () => {
    const view = mdView('a', { cursor: 1, deadKeyCommitDedupe: true });
    compose(view, '^');
    expect(await insertText(view, 'ê')).toBe(false);
    expect(view.state.doc.toString()).toBe('aê');
  });

  it('a keydown between the inserts resets the state', async () => {
    const view = mdView('a', { cursor: 1, deadKeyCommitDedupe: true });
    compose(view, '^');
    expect(await insertText(view, '^')).toBe(false);
    view.contentDOM.dispatchEvent(
      new KeyboardEvent('keydown', { key: '2', bubbles: true }),
    );
    // A genuine `^2` typed later is a real edit, not the duplicate commit.
    expect(await insertText(view, '^2')).toBe(false);
    expect(view.state.doc.toString()).toBe('a^^2');
  });

  it('leaves a plain insert with no preceding composition alone', async () => {
    const view = mdView('a', { cursor: 1, deadKeyCommitDedupe: true });
    expect(await insertText(view, '^2')).toBe(false);
    expect(view.state.doc.toString()).toBe('a^2');
  });

  it('behaves the same in tex', async () => {
    const view = langView('a', 'tex', { cursor: 1, deadKeyCommitDedupe: true });
    compose(view, '^');
    expect(await insertText(view, '^')).toBe(false);
    expect(await insertText(view, '^2')).toBe(true);
    expect(view.state.doc.toString()).toBe('a^2');
  });
});
