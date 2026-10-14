import { describe, it, expect, afterEach, vi } from 'vitest';
import { SearchQuery, openSearchPanel, closeSearchPanel } from '@codemirror/search';
import { destroyViews, mdView } from './helpers/views';

/**
 * The find panel scans the whole document for its "3/7" count. A keystroke in
 * the find field used to scan three times (the query-change recount, the
 * select-from-anchor pass, the commit's own recount) and a toggle likewise;
 * one scan per query and document is enough.
 */
describe('find panel match scans', () => {
  afterEach(() => {
    vi.restoreAllMocks();
    destroyViews();
  });

  const DOC = 'alpha beta alpha\ngamma alpha\n\nbeta alpha';

  function openPanel() {
    const view = mdView(DOC, { cursor: 0 });
    openSearchPanel(view);
    const input = view.dom.querySelector<HTMLInputElement>('.chalk-find__input')!;
    const count = view.dom.querySelector<HTMLElement>('.chalk-find__count')!;
    return { view, input, count };
  }

  it('scans once per keystroke and selects the first match', () => {
    const { view, input, count } = openPanel();
    const scans = vi.spyOn(SearchQuery.prototype, 'getCursor');
    input.value = 'alph';
    input.dispatchEvent(new Event('input'));
    expect(scans).toHaveBeenCalledTimes(1);
    expect(count.textContent).toBe('1/4');
    expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe('alph');
    input.value = 'alpha';
    input.dispatchEvent(new Event('input'));
    expect(scans).toHaveBeenCalledTimes(2);
    expect(count.textContent).toBe('1/4');
  });

  it('scans once per toggle', () => {
    const { view, input, count } = openPanel();
    input.value = 'Alpha';
    input.dispatchEvent(new Event('input'));
    const scans = vi.spyOn(SearchQuery.prototype, 'getCursor');
    view.dom.querySelector<HTMLButtonElement>('.chalk-find__toggle')!.click(); // Match case
    expect(scans).toHaveBeenCalledTimes(1);
    expect(count.textContent).toBe('No results');
  });

  it('does not rescan to step through matches or to close', () => {
    const { view, input, count } = openPanel();
    input.value = 'alpha';
    input.dispatchEvent(new Event('input'));
    const scans = vi.spyOn(SearchQuery.prototype, 'getCursor');
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
    expect(count.textContent).toBe('2/4');
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true }));
    expect(count.textContent).toBe('1/4');
    view.dispatch({ changes: { from: 0, insert: 'x' } }); // schedules a recount
    closeSearchPanel(view);
    expect(scans).toHaveBeenCalledTimes(0);
  });

  it('recounts after an edit', async () => {
    vi.useFakeTimers();
    try {
      const { view, input, count } = openPanel();
      input.value = 'alpha';
      input.dispatchEvent(new Event('input'));
      view.dispatch({ changes: { from: view.state.doc.length, insert: ' alpha' } });
      vi.advanceTimersByTime(150);
      expect(count.textContent).toBe('1/5');
    } finally {
      vi.useRealTimers();
    }
  });
});
