import { describe, it, expect } from 'vitest';
import { hangColumns } from '../src/editor/hanging-indent';

describe('hangColumns', () => {
  it('returns 0 for an unindented paragraph line', () => {
    expect(hangColumns('Just some prose that will wrap.')).toBe(0);
  });

  it('returns 0 for a heading (not a list marker)', () => {
    expect(hangColumns('# A heading')).toBe(0);
    expect(hangColumns('### Deeper heading')).toBe(0);
  });

  it('counts leading whitespace for indented prose', () => {
    expect(hangColumns('    indented continuation prose')).toBe(4);
  });

  it('hangs under the text of a bullet item', () => {
    expect(hangColumns('- item text')).toBe(2); // "- "
    expect(hangColumns('* item text')).toBe(2);
    expect(hangColumns('+ item text')).toBe(2);
  });

  it('includes indentation before a nested bullet', () => {
    expect(hangColumns('    - nested item')).toBe(6); // 4 + "- "
  });

  it('hangs under the text of an ordered item', () => {
    expect(hangColumns('1. first')).toBe(3); // "1. "
    expect(hangColumns('12) twelfth')).toBe(4); // "12) "
  });

  it('hangs under the text past a task-list checkbox', () => {
    expect(hangColumns('- [ ] todo text')).toBe(6); // "- [ ] "
    expect(hangColumns('- [x] done text')).toBe(6);
  });

  it('hangs under the text of a LaTeX \\item', () => {
    expect(hangColumns('\\item the item body')).toBe(6); // "\item "
    expect(hangColumns('    \\item indented item')).toBe(10); // 4 + "\item "
  });

  it('expands tabs to the tab stop', () => {
    expect(hangColumns('\tindented', 4)).toBe(4);
    expect(hangColumns('\t- bullet', 4)).toBe(6); // tab(4) + "- "
    expect(hangColumns('\tindented', 2)).toBe(2);
  });

  it('requires a space after the marker (a bare dash is not a bullet)', () => {
    expect(hangColumns('-no space')).toBe(0);
    expect(hangColumns('1.no space')).toBe(0);
  });
});
