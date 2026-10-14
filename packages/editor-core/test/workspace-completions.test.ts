import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { CompletionContext, type CompletionResult } from '@codemirror/autocomplete';
import { latexCompletionSource } from '../src/editor/latex-completions';
import { mdCompletionSource } from '../src/editor/md-completions';
import {
  workspaceAccessFacet,
  bibliographyKeys,
  type WorkspaceAccess,
  type WorkspaceFileKind,
} from '../src/editor/workspace-files';

/**
 * File and bibliography completion. The host walks the workspace (it owns
 * path resolution and sandbox scope); editor-core only asks. These drive a
 * stub host, so the parsing and caching are covered without a filesystem —
 * the same split `resolveAssetPath` uses on the asset side.
 */
const FILES: Record<WorkspaceFileKind, string[]> = {
  image: ['figures/plot.png', 'figures/scan.jpg', 'diagram.pdf'],
  document: ['chapters/intro.tex', 'notes.md'],
  bib: ['refs.bib'],
};

const BIB = `
% a comment line
@string{jphys = "Journal of Physics"}

@article{einstein1905,
  title = {On the electrodynamics of moving bodies},
}
@book{ knuth1984 ,
  title = {The TeXbook},
}
`;

function stubHost(overrides: Partial<WorkspaceAccess> = {}) {
  const calls: WorkspaceFileKind[][] = [];
  const access: WorkspaceAccess = {
    list: async (kinds) => {
      calls.push([...kinds]);
      return kinds.flatMap((k) => FILES[k]);
    },
    readText: async (path) => (path.endsWith('.bib') ? BIB : null),
    ...overrides,
  };
  return { access, calls };
}

async function completeAt(
  docWithCaret: string,
  language: 'tex' | 'md',
  access: WorkspaceAccess,
): Promise<CompletionResult | null> {
  const pos = docWithCaret.indexOf('|');
  const doc = docWithCaret.slice(0, pos) + docWithCaret.slice(pos + 1);
  const state = EditorState.create({
    doc,
    selection: { anchor: pos },
    extensions: [workspaceAccessFacet.of(access)],
  });
  const source = language === 'tex' ? latexCompletionSource : mdCompletionSource;
  return await source(new CompletionContext(state, pos, false));
}

async function labelsAt(
  docWithCaret: string,
  language: 'tex' | 'md',
  access: WorkspaceAccess,
): Promise<string[]> {
  const result = await completeAt(docWithCaret, language, access);
  return result ? result.options.map((o) => o.label) : [];
}

describe('bibliography key parsing', () => {
  it('reads the keys out of a bib file', () => {
    expect(bibliographyKeys(BIB)).toEqual(['einstein1905', 'knuth1984']);
  });

  it('ignores @string, @comment and @preamble entries', () => {
    const keys = bibliographyKeys(
      '@comment{ignore}\n@preamble{"x"}\n@string{a = "b"}\n@misc{real,}\n',
    );
    expect(keys).toEqual(['real']);
  });

  it('survives a file with no entries', () => {
    expect(bibliographyKeys('just prose\n')).toEqual([]);
  });
});

describe('file completion in tex', () => {
  it('offers images after \\includegraphics{', async () => {
    const { access } = stubHost();
    const offered = await labelsAt('\\includegraphics{|', 'tex', access);
    expect(offered).toContain('figures/plot.png');
    expect(offered).not.toContain('notes.md');
  });

  it('offers documents after \\input{', async () => {
    const { access } = stubHost();
    const offered = await labelsAt('\\input{|', 'tex', access);
    expect(offered).toContain('chapters/intro.tex');
    expect(offered).not.toContain('figures/plot.png');
  });

  it('asks the host only for the kind it needs', async () => {
    const { access, calls } = stubHost();
    await labelsAt('\\includegraphics{|', 'tex', access);
    expect(calls).toEqual([['image']]);
  });

  it('degrades to nothing when the host lists no files', async () => {
    const { access } = stubHost({ list: async () => [] });
    expect(await labelsAt('\\includegraphics{|', 'tex', access)).toEqual([]);
  });

  it('degrades to nothing when there is no host at all', async () => {
    const pos = '\\includegraphics{'.length;
    const state = EditorState.create({ doc: '\\includegraphics{', selection: { anchor: pos } });
    const result = await latexCompletionSource(new CompletionContext(state, pos, false));
    expect(result?.options ?? []).toEqual([]);
  });
});

describe('citation completion', () => {
  it('offers keys from the bib files the host lists', async () => {
    const { access } = stubHost();
    const offered = await labelsAt('\\cite{|', 'tex', access);
    expect(offered).toEqual(expect.arrayContaining(['einstein1905', 'knuth1984']));
  });

  it('keeps in-document bibitem keys alongside them', async () => {
    const { access } = stubHost();
    const offered = await labelsAt('\\bibitem{local} X\n\\cite{|', 'tex', access);
    expect(offered).toEqual(expect.arrayContaining(['local', 'einstein1905']));
  });

  it('names the file each key came from', async () => {
    const { access } = stubHost();
    const result = await completeAt('\\cite{|', 'tex', access);
    expect(result?.options.find((o) => o.label === 'knuth1984')?.detail).toContain('refs.bib');
  });
});

describe('file completion in markdown', () => {
  it('offers images inside an image link', async () => {
    const { access } = stubHost();
    const offered = await labelsAt('![plot](|', 'md', access);
    expect(offered).toContain('figures/plot.png');
  });

  it('offers documents and images inside a plain link', async () => {
    const { access } = stubHost();
    const offered = await labelsAt('[see](|', 'md', access);
    expect(offered).toEqual(expect.arrayContaining(['notes.md', 'figures/plot.png']));
  });

  it('keeps completing once part of the path is typed', async () => {
    const { access } = stubHost();
    expect(await labelsAt('![](figures/pl|', 'md', access)).toContain('figures/plot.png');
  });
});

describe('listing cache', () => {
  it('asks the host once for a burst of completions', async () => {
    const { access, calls } = stubHost();
    await labelsAt('\\includegraphics{|', 'tex', access);
    await labelsAt('\\includegraphics{fig|', 'tex', access);
    await labelsAt('\\includegraphics{figures/|', 'tex', access);
    expect(calls.length).toBe(1);
  });

  it('keeps separate entries per kind', async () => {
    const { access, calls } = stubHost();
    await labelsAt('\\includegraphics{|', 'tex', access);
    await labelsAt('\\input{|', 'tex', access);
    expect(calls).toEqual([['image'], ['document']]);
  });
});
