import { describe, expect, it } from 'vitest';
import { findLatexRoot, includedTexFiles, type RootFinderFs } from '../../src/extension/latex/root-finder';

function memFs(files: Record<string, string>): RootFinderFs {
  return {
    readFile: (p) => (p in files ? files[p] : null),
    exists: (p) => p in files,
    listTexFiles: () => Object.keys(files).filter((p) => p.endsWith('.tex')),
  };
}

const WS = '/ws';

describe('findLatexRoot: magic comment', () => {
  it('resolves a relative % !TEX root against the saved file dir', () => {
    const fs = memFs({
      '/ws/paper/article/2_method.tex': '% !TEX root = main.tex\n\\section{Method}\n',
      '/ws/paper/article/main.tex': '\\documentclass{article}\n',
    });
    const r = findLatexRoot('/ws/paper/article/2_method.tex', fs, { workspaceDir: WS });
    expect(r.root).toBe('/ws/paper/article/main.tex');
    expect(r.reason).toContain('magic comment');
  });

  it('accepts ../ paths, case-insensitive tag, and missing .tex extension', () => {
    const fs = memFs({
      '/ws/sub/chapter.tex': '%!tex ROOT = ../main\ntext\n',
      '/ws/main.tex': '\\documentclass{book}\n',
    });
    expect(findLatexRoot('/ws/sub/chapter.tex', fs, {}).root).toBe('/ws/main.tex');
  });

  it('beats the configured root', () => {
    const fs = memFs({
      '/ws/a.tex': '% !TEX root = b.tex\n',
      '/ws/b.tex': '\\documentclass{article}',
      '/ws/other.tex': '\\documentclass{article}',
    });
    const r = findLatexRoot('/ws/a.tex', fs, { configuredRoot: 'other.tex', workspaceDir: WS });
    expect(r.root).toBe('/ws/b.tex');
  });

  it('reports a dangling magic target instead of falling through', () => {
    const fs = memFs({ '/ws/a.tex': '% !TEX root = gone.tex\n\\documentclass{article}\n' });
    const r = findLatexRoot('/ws/a.tex', fs, {});
    expect(r.root).toBeNull();
    expect(r.reason).toContain('missing');
  });
});

describe('findLatexRoot: configured root and self', () => {
  it('uses chalk.latex.rootFile relative to the workspace', () => {
    const fs = memFs({
      '/ws/notes/frag.tex': 'no class here\n',
      '/ws/paper/main.tex': '\\documentclass{article}\n',
    });
    const r = findLatexRoot('/ws/notes/frag.tex', fs, {
      configuredRoot: 'paper/main.tex',
      workspaceDir: WS,
    });
    expect(r.root).toBe('/ws/paper/main.tex');
    expect(r.reason).toContain('setting');
  });

  it('picks the saved file itself when it has \\documentclass', () => {
    const fs = memFs({ '/ws/standalone.tex': '\\documentclass{article}\n\\begin{document}x\\end{document}\n' });
    const r = findLatexRoot('/ws/standalone.tex', fs, { workspaceDir: WS });
    expect(r.root).toBe('/ws/standalone.tex');
  });

  it('ignores a commented-out \\documentclass', () => {
    const fs = memFs({ '/ws/frag.tex': '% \\documentclass{article}\ntext only\n' });
    expect(findLatexRoot('/ws/frag.tex', fs, { workspaceDir: WS }).root).toBeNull();
  });
});

describe('findLatexRoot: include graph', () => {
  it('finds the root that transitively includes the saved file', () => {
    const fs = memFs({
      '/ws/paper/main.tex':
        '\\documentclass{article}\n\\begin{document}\n\\input{sections/all}\n\\end{document}\n',
      '/ws/paper/sections/all.tex': '\\include{sections/2_method}\n',
      '/ws/paper/sections/2_method.tex': '\\section{Method}\n',
    });
    const r = findLatexRoot('/ws/paper/sections/2_method.tex', fs, { workspaceDir: WS });
    expect(r.root).toBe('/ws/paper/main.tex');
    expect(r.reason).toContain('include graph');
  });

  it('resolves include paths against the ROOT dir, not the including file', () => {
    // main.tex includes sections/all.tex which includes sections/deep.tex —
    // written as "sections/deep" because TeX resolves against the compile dir.
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\input{sections/all}\n',
      '/ws/sections/all.tex': '\\input{sections/deep}\n',
      '/ws/sections/deep.tex': 'content\n',
    });
    expect(findLatexRoot('/ws/sections/deep.tex', fs, { workspaceDir: WS }).root).toBe('/ws/main.tex');
  });

  it('ignores commented-out includes and non-root candidates', () => {
    const fs = memFs({
      '/ws/decoy.tex': '\\documentclass{article}\n% \\input{frag}\n',
      '/ws/frag.tex': 'text\n',
    });
    expect(findLatexRoot('/ws/frag.tex', fs, { workspaceDir: WS }).root).toBeNull();
  });

  it('supports \\import{dir}{file}', () => {
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\import{parts/}{intro}\n',
      '/ws/parts/intro.tex': 'intro\n',
    });
    expect(findLatexRoot('/ws/parts/intro.tex', fs, { workspaceDir: WS }).root).toBe('/ws/main.tex');
  });

  it('survives include cycles', () => {
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\input{a}\n',
      '/ws/a.tex': '\\input{b}\n',
      '/ws/b.tex': '\\input{a}\n',
      '/ws/orphan.tex': 'nope\n',
    });
    expect(findLatexRoot('/ws/orphan.tex', fs, { workspaceDir: WS }).root).toBeNull();
  });
});

describe('includedTexFiles', () => {
  it('returns the root and its readable include closure, resolved against the root dir', () => {
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\input{sections/intro}\n\\include{sections/method.tex}\n% \\input{commented}\n',
      '/ws/sections/intro.tex': '\\import{shared/}{macros}\n',
      '/ws/sections/method.tex': 'text\n',
      '/ws/shared/macros.tex': '\\input{sections/intro}\n',
    });
    expect(includedTexFiles('/ws/main.tex', fs)).toEqual([
      '/ws/main.tex',
      '/ws/sections/intro.tex',
      '/ws/sections/method.tex',
      '/ws/shared/macros.tex',
    ]);
  });

  it('skips unreadable targets and survives an include cycle', () => {
    const fs = memFs({
      '/ws/a.tex': '\\input{b}\n\\input{missing}\n',
      '/ws/b.tex': '\\input{a}\n',
    });
    expect(includedTexFiles('/ws/a.tex', fs)).toEqual(['/ws/a.tex', '/ws/b.tex']);
  });
});
