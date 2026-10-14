import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';
import { tableField } from '../src/editor/table-field';
import type { TableWidget } from '../src/editor/table-widget';

// ---------------------------------------------------------------------------
//  M-16: buffered cell edits vs. external changes to the document.
//
//  Cell edits buffer in the widget's contenteditable DOM and normally flush on
//  blur/Escape/structural op. These tests pin what happens when the document
//  changes UNDER the widget before that flush:
//   (a) edits elsewhere in the doc reuse the table DOM (widget eq) — the
//       buffer survives untouched;
//   (b) an external rewrite of the TABLE source itself drops the buffer and
//       never dispatches into the rewritten text (conservative: a dropped
//       buffer is recoverable, a flush into a stale range corrupts);
//   (c) destroy() flushes the buffer when the DOM is still resolvable
//       (posAtDOM succeeds and the range still holds the widget's table);
//   (d) a widget rebuild that does NOT change the table source (callout flags
//       flip when the caret reveals the `:::` fence) flushes the buffer via
//       updateDOM instead of dropping it.
// ---------------------------------------------------------------------------

const TABLE = '| a | b |\n| --- | --- |\n| 1 | 2 |';

/** Let CM6's sync + our queueMicrotask-deferred flush settle. */
async function settle(): Promise<void> {
  await new Promise((r) => setTimeout(r, 20));
}

function firstTableWidget(view: EditorView): TableWidget {
  const field = view.state.field(tableField);
  const cur = field.iter();
  expect(cur.value).not.toBeNull();
  return (cur.value!.spec as { widget: TableWidget }).widget;
}

describe('buffered cell edits vs external document changes', () => {
  let parent: HTMLElement;
  let view: EditorView;

  beforeEach(() => {
    document.body.innerHTML = '';
    parent = document.createElement('div');
    document.body.appendChild(parent);
  });

  afterEach(() => {
    view.destroy();
    parent.remove();
  });

  it('(a) typing elsewhere reuses the table DOM and keeps the buffer', async () => {
    view = parsed(createEditor(parent, `before\n\n${TABLE}\n\nafter`, { onContentChange: () => {} }, 'md'));
    const td = view.dom.querySelector<HTMLElement>('tbody td')!;
    td.textContent = 'edited';

    view.dispatch({ changes: { from: 0, to: 0, insert: 'X' } });
    await settle();

    // Same element, buffer intact — eq() reused the DOM.
    expect(view.dom.querySelector<HTMLElement>('tbody td')).toBe(td);
    expect(td.textContent).toBe('edited');
    // The buffer is still un-flushed (that is the design: flush on blur).
    expect(view.state.doc.toString()).toContain('| 1 | 2 |');
  });

  it('(b) an external rewrite of the table source drops the buffer without corrupting it', async () => {
    view = parsed(createEditor(parent, `before\n\n${TABLE}\n\nafter`, { onContentChange: () => {} }, 'md'));
    const td = view.dom.querySelector<HTMLElement>('tbody td')!;
    td.focus();
    td.textContent = 'edited';

    // Host-side update rewrites the table region itself.
    const doc = view.state.doc.toString();
    const from = doc.indexOf('| a');
    const to = from + TABLE.length;
    const external = '| x | y |\n| --- | --- |\n| 9 | 8 |';
    view.dispatch({ changes: { from, to, insert: external } });
    await settle();

    // The external text won; the stale buffer was dropped, not dispatched.
    const after = view.state.doc.toString();
    expect(after).toContain('| 9 | 8 |');
    expect(after).not.toContain('edited');
    // And the widget now renders the external content.
    expect(view.dom.querySelector<HTMLElement>('tbody td')!.textContent).toBe('9');
  });

  it('(c) destroy() flushes a dirty buffer while posAtDOM still resolves', async () => {
    view = parsed(createEditor(parent, `before\n\n${TABLE}\n\nafter`, { onContentChange: () => {} }, 'md'));
    const td = view.dom.querySelector<HTMLElement>('tbody td')!;
    td.textContent = 'edited';

    const wrap = view.dom.querySelector<HTMLElement>('.cm-live-table-wrap')!;
    const widget = firstTableWidget(view);
    // Simulate CM6 teardown: destroy is called, then the DOM detaches. The
    // removal must be hidden from CM6's DOM observer (as CM6's own updateInner
    // does) or it reads the vanished widget as a user deletion of the range.
    widget.destroy(wrap);
    (view as unknown as { observer: { ignore(f: () => void): void } }).observer.ignore(() =>
      wrap.remove(),
    );
    await settle();

    expect(view.state.doc.toString()).toContain('| edited | 2');
  });

  it('(c2) destroy() with a clean buffer dispatches nothing', async () => {
    view = parsed(createEditor(parent, `before\n\n${TABLE}\n\nafter`, { onContentChange: () => {} }, 'md'));
    const before = view.state.doc.toString();
    const wrap = view.dom.querySelector<HTMLElement>('.cm-live-table-wrap')!;
    const widget = firstTableWidget(view);
    widget.destroy(wrap);
    await settle();
    expect(view.state.doc.toString()).toBe(before);
  });

  it('(d) a source-preserving widget rebuild flushes the buffer via updateDOM', async () => {
    // Table is the last body element of a callout: moving the caret onto the
    // collapsed `:::` fence flips the widget's callout flags (bottom/hideTo),
    // rebuilding it with the SAME table source — the buffered edit must land
    // in the document instead of dying with the discarded DOM.
    const src = '::: {.callout-note}\ntext\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n:::\n\nafter';
    view = parsed(createEditor(parent, src, { onContentChange: () => {} }, 'md'));
    // Park the caret on a body line so the fence starts out collapsed.
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('text')) });
    await settle();

    const td = view.dom.querySelector<HTMLElement>('tbody td')!;
    td.textContent = 'edited';

    // Caret onto the close fence line → selection-driven rebuild, same source.
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('\n:::') + 1) });
    await settle();

    expect(view.state.doc.toString()).toContain('| edited | 2');
  });
});
