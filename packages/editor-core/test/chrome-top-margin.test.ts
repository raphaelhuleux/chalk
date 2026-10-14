import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EditorView } from '@codemirror/view';
import { createEditor } from '../src/editor/setup';

/**
 * The native hosts overlay a translucent chrome band on the editor's top edge
 * and publish its height as `--chalk-chrome-top`. Scroll-into-view must treat
 * that band as occluded — otherwise Cmd+Up lands the caret at the scroller's
 * top edge, hidden UNDER the band (live bug, 2026-08-14). jsdom can't measure
 * real scroll geometry (the Playwright harness covers that); this locks the
 * facet wiring: a scrollMargins entry that reads the live CSS variable.
 */
describe('chrome-top scroll margin', () => {
  let parent: HTMLElement;
  let view: EditorView;

  beforeEach(() => {
    document.body.innerHTML = '';
    parent = document.createElement('div');
    document.body.appendChild(parent);
  });

  afterEach(() => {
    view.destroy();
    document.documentElement.style.removeProperty('--chalk-chrome-top');
  });

  function marginTop(v: EditorView): number {
    let top = 0;
    for (const source of v.state.facet(EditorView.scrollMargins)) {
      top += source(v)?.top ?? 0;
    }
    return top;
  }

  it('reports the live --chalk-chrome-top value as a top scroll margin', () => {
    document.documentElement.style.setProperty('--chalk-chrome-top', '76px');
    view = createEditor(parent, 'hello', { onContentChange: () => {} }, 'md');
    expect(marginTop(view)).toBe(76);
  });

  it('contributes no top margin when the host sets no chrome inset', () => {
    view = createEditor(parent, 'hello', { onContentChange: () => {} }, 'md');
    expect(marginTop(view)).toBe(0);
  });

  it('tracks changes to the variable without a rebuild (read per scroll)', () => {
    document.documentElement.style.setProperty('--chalk-chrome-top', '40px');
    view = createEditor(parent, 'hello', { onContentChange: () => {} }, 'md');
    expect(marginTop(view)).toBe(40);
    document.documentElement.style.setProperty('--chalk-chrome-top', '57px');
    expect(marginTop(view)).toBe(57);
  });

  it('never resolves computed style per query (scrollMargins runs per keystroke)', () => {
    // CM6 consults scrollMargins in the measure phase of every scroll-into-view
    // — i.e. every keystroke — right after decorations mutate the DOM.
    // getComputedStyle there forces a whole-document style recalc (live perf
    // bug, 2026-08-14). The hosts publish the band height as an INLINE style
    // on documentElement (WebEditorSurface.applyChromeTopInset), so the margin
    // must read the inline declaration, never the cascade.
    document.documentElement.style.setProperty('--chalk-chrome-top', '76px');
    view = createEditor(parent, 'hello', { onContentChange: () => {} }, 'md');
    const spy = vi.spyOn(window, 'getComputedStyle');
    try {
      expect(marginTop(view)).toBe(76);
      expect(spy).not.toHaveBeenCalled();
    } finally {
      spy.mockRestore();
    }
  });
});
