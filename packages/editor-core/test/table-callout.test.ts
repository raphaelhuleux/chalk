import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { tableField } from '../src/editor/table-field';
import { destroyViews, mdView } from './helpers/views';

// ---------------------------------------------------------------------------
//  M-17: tables inside callouts must continue the admonition box.
//
//  The table wrap is a block-replace widget, not a `.cm-line`, so the callout
//  field's per-line tint/border can't reach it. buildTableDecorations tags the
//  widget with the callout {type, bottom} (→ `cm-callout cm-callout-<type>`
//  [+ `cm-callout-bottom`] on the wrap) and, when the table is the box's last
//  body element, extends the replace to `hideTo` so the collapsed `:::` fence
//  is absorbed — the same phantom-residue-row fix the math widgets use.
// ---------------------------------------------------------------------------

describe('tables inside callouts', () => {
  let view: EditorView;

  afterEach(destroyViews);

  const mount = (src: string): EditorView => mdView(src);

  it('tags the wrap with callout classes and absorbs the closing fence when last in the box', () => {
    const src = '::: {.callout-note}\ntext\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n:::\n\nafter';
    view = mount(src);
    // Park the caret on a body line so both fences are collapsed.
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('text')) });

    const wrap = view.dom.querySelector<HTMLElement>('.cm-live-table-wrap')!;
    expect(wrap.classList.contains('cm-callout')).toBe(true);
    expect(wrap.classList.contains('cm-callout-note')).toBe(true);
    expect(wrap.classList.contains('cm-callout-bottom')).toBe(true);
    // The `:::` close fence is absorbed by the widget's replace (hideTo):
    // no raw fence text — and no phantom residue row — anywhere in the DOM.
    expect(view.contentDOM.textContent).not.toContain(':::');
  });

  it('reveals the fence (and drops bottom) when the caret moves onto the fence line', () => {
    const src = '::: {.callout-note}\ntext\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n:::\n\nafter';
    view = mount(src);
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('text')) });
    expect(view.contentDOM.textContent).not.toContain(':::');

    // Caret onto the close fence line: hideTo is selection-aware, so the
    // tableField must rebuild on this selection-only transaction.
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('\n:::') + 1) });

    expect(view.contentDOM.textContent).toContain(':::');
    const wrap = view.dom.querySelector<HTMLElement>('.cm-live-table-wrap')!;
    // Still tinted, but the revealed fence line carries the box bottom now.
    expect(wrap.classList.contains('cm-callout-note')).toBe(true);
    expect(wrap.classList.contains('cm-callout-bottom')).toBe(false);
  });

  it('keeps the set on selection moves that touch no close fence', () => {
    const src =
      '::: {.callout-note}\ntext\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n:::\n\nafter\n\nmore prose';
    view = mount(src);
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('after')) });
    const before = view.state.field(tableField);
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('more')) });
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('text')) });
    view.dispatch({ selection: EditorSelection.range(src.indexOf('after'), src.indexOf('prose')) });
    expect(view.state.field(tableField)).toBe(before);
    // A selection end on the close fence line still rebuilds.
    view.dispatch({ selection: EditorSelection.range(src.indexOf('after'), src.indexOf('\n:::') + 2) });
    expect(view.state.field(tableField)).not.toBe(before);
  });

  it('tints a table in the middle of a callout without the bottom corner', () => {
    const src = '::: {.callout-note}\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nmore text\n:::\n\nafter';
    view = mount(src);
    view.dispatch({ selection: EditorSelection.cursor(src.indexOf('more text')) });

    const wrap = view.dom.querySelector<HTMLElement>('.cm-live-table-wrap')!;
    expect(wrap.classList.contains('cm-callout')).toBe(true);
    expect(wrap.classList.contains('cm-callout-note')).toBe(true);
    expect(wrap.classList.contains('cm-callout-bottom')).toBe(false);
    // Mid-box table doesn't absorb anything: the fence stays collapsed by the
    // CALLOUT field, so there is still no raw `:::` in the DOM.
    expect(view.contentDOM.textContent).not.toContain(':::');
  });

  it('leaves a table outside any callout untagged', () => {
    view = mount('before\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter');
    const wrap = view.dom.querySelector<HTMLElement>('.cm-live-table-wrap')!;
    expect(wrap.classList.contains('cm-callout')).toBe(false);
  });
});
