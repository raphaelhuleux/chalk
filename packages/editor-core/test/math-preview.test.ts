import { describe, it, expect, afterEach, beforeEach, vi } from 'vitest';
import { EditorView } from '@codemirror/view';
import { destroyViews, langView } from './helpers/views';

// Audit M-13 + M-22: while editing inside a display-math region the preview
// must (a) never go blank on a momentarily-invalid source — it falls back to
// the block's own last valid render — and (b) re-render on the keystroke only
// while the last render was cheap; a slow one waits for the 150ms debouncer.

const mount = (content: string, language: 'tex' | 'md'): EditorView =>
  langView(content, language);

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  destroyViews();
});

function texPreview(v: EditorView): HTMLElement | null {
  return v.dom.querySelector<HTMLElement>('.cm-tex-math-preview');
}
function mdPreview(v: EditorView): HTMLElement | null {
  return v.dom.querySelector<HTMLElement>('.cm-math-preview');
}

describe('tex display preview under invalid mid-edit states', () => {
  it('keeps showing the last valid render instead of going blank', () => {
    const v = mount('intro\n\\[\n\\frac{1}{2}\n\\]\nafter', 'tex');
    // Caret onto the math body line: reveal + preview (refresh build).
    v.dispatch({ selection: { anchor: v.state.doc.line(3).from + 2 } });
    const before = texPreview(v);
    expect(before).not.toBeNull();
    expect(before!.innerHTML).toContain('katex');
    const validHtml = before!.innerHTML;

    // Break the source: insert an unmatched brace (typing-shaped transaction).
    v.dispatch({
      changes: { from: v.state.doc.line(3).from + 2, insert: '{' },
      selection: { anchor: v.state.doc.line(3).from + 3 },
    });
    // Keystroke path: preview still present, still showing valid content.
    expect(texPreview(v)!.innerHTML).toBe(validHtml);

    // Debouncer fires: source is now invalid → preview falls back to the
    // last valid render, never an empty strip.
    vi.advanceTimersByTime(200);
    const after = texPreview(v);
    expect(after).not.toBeNull();
    expect(after!.innerHTML).not.toBe('');
    expect(after!.innerHTML).toContain('katex');
  });

  it('advances to the new content once it renders again', () => {
    const v = mount('intro\n\\[\nx=1\n\\]\nafter', 'tex');
    v.dispatch({ selection: { anchor: v.state.doc.line(3).from + 1 } });
    const line3 = v.state.doc.line(3);
    // Replace x=1 with y=2 (valid), then let the debouncer refresh.
    v.dispatch({
      changes: { from: line3.from, to: line3.to, insert: 'y=2' },
      selection: { anchor: line3.from + 1 },
    });
    vi.advanceTimersByTime(200);
    const p = texPreview(v);
    expect(p).not.toBeNull();
    // KaTeX encodes the identifiers as rendered spans; y must appear.
    expect(p!.textContent).toContain('y');
  });
});

describe('md display preview under invalid mid-edit states', () => {
  it('keeps showing the last valid render instead of going blank', () => {
    const v = mount('intro\n\n$$\n\\frac{1}{2}\n$$\n\nafter', 'md');
    v.dispatch({ selection: { anchor: v.state.doc.line(4).from + 2 } });
    const before = mdPreview(v);
    expect(before).not.toBeNull();
    expect(before!.innerHTML).toContain('katex');

    v.dispatch({
      changes: { from: v.state.doc.line(4).from + 2, insert: '{' },
      selection: { anchor: v.state.doc.line(4).from + 3 },
    });
    vi.advanceTimersByTime(200);
    const after = mdPreview(v);
    expect(after).not.toBeNull();
    expect(after!.innerHTML).not.toBe('');
    expect(after!.innerHTML).toContain('katex');
  });
});

// ---------------------------------------------------------------------------
// Two editors, one module. The debounced preview slot (the last valid render
// and the debounced source) used to be module-level, so a second mounted
// editor wiped the first one's fallback: any editor whose caret sits outside
// math clears the slot on every build. The visible symptom is the first
// editor's preview going blank on the next keystroke over an invalid source.
// ---------------------------------------------------------------------------

describe('the preview slot belongs to one editor instance', () => {
  // Both editors stay mounted at once, so this one must NOT clear the body.
  const mountKeep = (content: string, language: 'tex' | 'md'): EditorView =>
    langView(content, language, { clearBody: false });

  afterEach(destroyViews);

  it('md: a second editor does not blank the first one\'s preview', () => {
    const a = mountKeep('intro\n\n$$\n\\alpha\n$$\n\nafter', 'md');
    a.dispatch({ selection: { anchor: a.state.doc.line(4).to } });
    const valid = mdPreview(a)!.innerHTML;
    expect(valid).toContain('katex');

    // Typing an invalid tail: the preview holds the last valid render.
    a.dispatch({
      changes: { from: a.state.doc.line(4).to, insert: '{' },
      selection: { anchor: a.state.doc.line(4).to + 1 },
    });
    expect(mdPreview(a)!.innerHTML).toBe(valid);

    // A second editor mounts with its caret outside math.
    mountKeep('other\n\n$$\n\\beta\n$$\n', 'md');

    // Back to typing in the first editor: its own fallback must still be there.
    a.dispatch({
      changes: { from: a.state.doc.line(4).to, insert: '{' },
      selection: { anchor: a.state.doc.line(4).to + 1 },
    });
    expect(mdPreview(a)!.innerHTML).toBe(valid);
  });

  it('tex: a second editor does not blank the first one\'s preview', () => {
    const a = mountKeep('intro\n\\[\n\\alpha\n\\]\nafter', 'tex');
    a.dispatch({ selection: { anchor: a.state.doc.line(3).to } });
    const valid = texPreview(a)!.innerHTML;
    expect(valid).toContain('katex');

    a.dispatch({
      changes: { from: a.state.doc.line(3).to, insert: '{' },
      selection: { anchor: a.state.doc.line(3).to + 1 },
    });
    expect(texPreview(a)!.innerHTML).toBe(valid);

    mountKeep('other\n\\[\n\\beta\n\\]\n', 'tex');

    a.dispatch({
      changes: { from: a.state.doc.line(3).to, insert: '{' },
      selection: { anchor: a.state.doc.line(3).to + 1 },
    });
    expect(texPreview(a)!.innerHTML).toBe(valid);
  });
});
