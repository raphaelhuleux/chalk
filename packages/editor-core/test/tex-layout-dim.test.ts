import { describe, it, expect, afterEach } from 'vitest';
import { Text } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { scanLayoutCommands } from '../src/editor/tex-layout-dim';
import { destroyViews, texView } from './helpers/views';

afterEach(destroyViews);

const found = (...lines: string[]): string[] => {
  const doc = Text.of(lines);
  return scanLayoutCommands(doc).map((r) => doc.sliceString(r.from, r.to));
};

const dimmed = (view: EditorView): string[] =>
  Array.from(view.dom.querySelectorAll('.cm-syntax-dim')).map((el) => el.textContent ?? '');

describe('scanLayoutCommands', () => {
  it('finds spacing, page and float commands with their arguments', () => {
    expect(found('\\vspace{-5mm}', 'a\\medskip b', '\\clearpage', '\\FloatBarrier', '\\hspace*{1em}x')).toEqual([
      '\\vspace{-5mm}',
      '\\medskip',
      '\\clearpage',
      '\\FloatBarrier',
      '\\hspace*{1em}',
    ]);
  });

  it('a \\\\ break with its optional length, never half of one', () => {
    expect(found('line\\\\[2mm]', 'end \\\\', 'x \\\\*')).toEqual(['\\\\[2mm]', '\\\\', '\\\\*']);
  });

  it('skips comments, verbatim and look-alike commands', () => {
    expect(found('text % \\vspace{1em}')).toEqual([]);
    expect(found('\\begin{verbatim}', '\\medskip', '\\end{verbatim}')).toEqual([]);
    expect(found('\\parbox{1em}{x} \\centeringx \\newpagestyle')).toEqual([]);
  });
});

describe('layout commands dim in preview and mixed', () => {
  const DOC = 'Text.\n\\medskip\nMore\\\\[2mm]\nand $a \\\\ b$ math.\nend';

  for (const viewMode of ['preview', 'mixed'] as const) {
    it(viewMode, () => {
      const view = texView(DOC, { viewMode, cursor: 'end' });
      expect(dimmed(view)).toEqual(expect.arrayContaining(['\\medskip', '\\\\[2mm]']));
      // `\\` inside math is a row end, not layout.
      expect(dimmed(view)).not.toContain('\\\\');
    });
  }

  it('source mode shows them plain', () => {
    const view = texView(DOC, { viewMode: 'source', cursor: 'end' });
    expect(dimmed(view)).not.toContain('\\medskip');
  });
});
