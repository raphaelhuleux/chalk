import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { extractOutline } from '../src/editor/outline';

/** The outline turns a deck into a slide list: number + frame title, in
 *  document order, indented under the enclosing \section. */

const outline = (doc: string) =>
  extractOutline(EditorState.create({ doc }), 'tex');

const BEAMER = '\\documentclass{beamer}\n';

describe('frames in the tex outline', () => {
  it('lists each frame as a numbered slide entry', () => {
    const items = outline(
      `${BEAMER}\\begin{frame}{Roadmap}\n\\end{frame}\n` +
        `\\begin{frame}{Identification}\n\\end{frame}`,
    ).filter((i) => i.kind === 'frame');
    expect(items.map((i) => [i.number, i.title])).toEqual([
      [1, 'Roadmap'],
      [2, 'Identification'],
    ]);
  });

  it('reads the \\frametitle form too', () => {
    const items = outline(
      `${BEAMER}\\begin{frame}[t]\n\\frametitle{Identification}\n\\end{frame}`,
    ).filter((i) => i.kind === 'frame');
    expect(items[0].title).toBe('Identification');
  });

  it('sits at level 0 so the panel indents it under its section', () => {
    const items = outline(
      `${BEAMER}\\section{Estimation}\n\\begin{frame}{Roadmap}\n\\end{frame}`,
    );
    expect(items.map((i) => [i.kind, i.level])).toEqual([
      ['heading', 3],
      ['frame', 0],
    ]);
  });

  it('merges into document order with sections', () => {
    const items = outline(
      `${BEAMER}\\begin{frame}{One}\n\\end{frame}\n` +
        `\\section{Middle}\n` +
        `\\begin{frame}{Two}\n\\end{frame}`,
    );
    expect(items.map((i) => i.title)).toEqual(['One', 'Middle', 'Two']);
  });

  it('gives a title-less frame an empty title rather than dropping it', () => {
    const items = outline(`${BEAMER}\\begin{frame}\n\\titlepage\n\\end{frame}`).filter(
      (i) => i.kind === 'frame',
    );
    expect(items).toHaveLength(1);
    expect(items[0].title).toBe('');
  });

  it('adds nothing for a document that is not beamer', () => {
    const items = outline('\\documentclass{article}\n\\begin{frame}\n\\end{frame}');
    expect(items.filter((i) => i.kind === 'frame')).toHaveLength(0);
  });
});
