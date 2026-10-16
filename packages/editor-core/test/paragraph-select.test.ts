import { describe, expect, it } from 'vitest';
import { EditorView } from '@codemirror/view';
import { EditorState } from '@codemirror/state';
import { paragraphSelectionStyle } from '../src/editor/paragraph-select';

/**
 * jsdom has no layout, so `posAtCoords` is stubbed to read a document offset
 * off the event's x; the browser twin is Tests/fixtures/mouse/23.
 */
function view(doc: string): EditorView {
  const v = new EditorView({ state: EditorState.create({ doc }) });
  v.posAtCoords = ((coords: { x: number }) => coords.x) as EditorView['posAtCoords'];
  return v;
}

const click = (pos: number, detail: number, button = 0): MouseEvent =>
  ({ clientX: pos, clientY: 0, detail, button }) as unknown as MouseEvent;

describe('triple-click paragraph selection', () => {
  const doc = 'alpha beta\ngamma delta\nepsilon';

  it('selects the paragraph without its line break', () => {
    const v = view(doc);
    const style = paragraphSelectionStyle(v, click(2, 3));
    const sel = style!.get(click(2, 3), false, false).main;
    expect(v.state.sliceDoc(sel.from, sel.to)).toBe('alpha beta');
  });

  it('extends by whole paragraphs when the drag continues, in either direction', () => {
    const v = view(doc);
    const down = paragraphSelectionStyle(v, click(13, 3))!;
    const below = down.get(click(25, 3), false, false).main;
    expect(v.state.sliceDoc(below.from, below.to)).toBe('gamma delta\nepsilon');
    const above = down.get(click(1, 3), false, false).main;
    expect(v.state.sliceDoc(above.from, above.to)).toBe('alpha beta\ngamma delta');
    expect(above.head).toBe(0);
  });

  it('leaves single and double clicks, and other buttons, to CodeMirror', () => {
    const v = view(doc);
    expect(paragraphSelectionStyle(v, click(2, 1))).toBeNull();
    expect(paragraphSelectionStyle(v, click(2, 2))).toBeNull();
    expect(paragraphSelectionStyle(v, click(2, 3, 2))).toBeNull();
  });
});
