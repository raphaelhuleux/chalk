import { describe, it, expect, beforeEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';

/**
 * Integration tests for tight bullet continuation. These mount a real md
 * editor and dispatch an actual Enter keydown so the full keymap chain runs —
 * verifying mdListNewlineKeymap wins over markdown()'s built-in
 * insertNewlineContinueMarkup (which loose-ifies lists with a blank line).
 */
function pressEnter(doc: string, line: number, col?: number): string {
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const view = parsed(createEditor(parent, doc, { onContentChange: () => {} }, 'md'));
  const ln = view.state.doc.line(line);
  view.dispatch({ selection: EditorSelection.cursor(col == null ? ln.to : ln.from + col) });
  view.contentDOM.dispatchEvent(
    new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }),
  );
  const out = view.state.doc.toString();
  view.destroy();
  parent.remove();
  return out;
}

describe('tight bullet continuation on Enter', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('continues a fresh bullet tightly', () => {
    expect(pressEnter('- foo', 1)).toBe('- foo\n- ');
  });

  it('continues a tight multi-item list tightly', () => {
    expect(pressEnter('- foo\n- bar', 2)).toBe('- foo\n- bar\n- ');
  });

  it('does NOT add a blank line in a loose list (the bug)', () => {
    // Pre-existing blank between foo/bar is the user's content; the NEW bullet
    // must be tight — previously this produced "...\n\n- bar\n\n- ".
    expect(pressEnter('- foo\n\n- bar', 3)).toBe('- foo\n\n- bar\n- ');
  });

  it('preserves indentation on a nested bullet', () => {
    expect(pressEnter('  - nested', 1)).toBe('  - nested\n  - ');
  });

  it('preserves the marker character (* and +)', () => {
    expect(pressEnter('* foo', 1)).toBe('* foo\n* ');
    expect(pressEnter('+ foo', 1)).toBe('+ foo\n+ ');
  });

  it('splits the item when Enter is pressed mid-text', () => {
    expect(pressEnter('- foobar', 1, 5)).toBe('- foo\n- bar'); // col 5 = after "- foo"
  });

  it('exits the list on an empty bullet (no blank line, marker removed)', () => {
    expect(pressEnter('- foo\n- ', 2)).toBe('- foo\n');
  });

  it('exits from an empty nested bullet', () => {
    expect(pressEnter('- a\n  - ', 2)).toBe('- a\n');
  });

  it('leaves ordered lists to the default (renumbering) command', () => {
    expect(pressEnter('1. foo', 1)).toBe('1. foo\n2. ');
  });

  it('continues a task item with an unchecked box', () => {
    expect(pressEnter('- [ ] foo', 1)).toBe('- [ ] foo\n- [ ] ');
    expect(pressEnter('  * [x] done', 1)).toBe('  * [x] done\n  * [ ] ');
  });

  it('exits the list on an empty task item', () => {
    expect(pressEnter('- [ ] foo\n- [ ] ', 2)).toBe('- [ ] foo\n');
  });

  it('does not continue a bullet inside a code fence', () => {
    expect(pressEnter('```\n- foo\n```', 2)).toBe('```\n- foo\n\n```');
  });

  it('does not continue a bullet inside frontmatter', () => {
    expect(pressEnter('---\ntags:\n- foo\n---\nbody', 3)).toBe('---\ntags:\n- foo\n\n---\nbody');
  });

  it('does not treat a non-list line as a bullet', () => {
    expect(pressEnter('just prose', 1)).toBe('just prose\n');
  });
});
