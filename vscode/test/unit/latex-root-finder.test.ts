import { describe, expect, it } from 'vitest';
import {
  findLatexRoot,
  includedTexFiles,
  parseFlsInputs,
  type RootFinderFs,
} from '../../src/extension/latex/root-finder';

function memFs(files: Record<string, string>, fls: Record<string, string[]> = {}): RootFinderFs {
  return {
    readFile: (p) => (p in files ? files[p] : null),
    exists: (p) => p in files,
    listTexFiles: () => Object.keys(files).filter((p) => p.endsWith('.tex')),
    flsInputs: (root) => fls[root] ?? [],
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

  it('reads the magic comment past the first lines of the file', () => {
    const fs = memFs({
      '/ws/ch.tex': `${'text\n'.repeat(40)}% !TEX root = main.tex\n`,
      '/ws/main.tex': '\\documentclass{article}\n',
    });
    expect(findLatexRoot('/ws/ch.tex', fs, {}).root).toBe('/ws/main.tex');
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

  it('supports the brace-less TeX \\input form', () => {
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\input chapters/one\n',
      '/ws/chapters/one.tex': 'one\n',
    });
    expect(findLatexRoot('/ws/chapters/one.tex', fs, { workspaceDir: WS }).root).toBe('/ws/main.tex');
  });

  it('does not take \\includegraphics or \\includeonly for includes', () => {
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\includeonly{frag}\n\\includegraphics{frag}\n',
      '/ws/frag.tex': 'x\n',
    });
    expect(findLatexRoot('/ws/frag.tex', fs, { workspaceDir: WS }).root).toBeNull();
  });

  it('resolves \\subimport against the importing file and inputs inside it against the import dir', () => {
    const fs = memFs({
      '/ws/main.tex': '\\documentclass{article}\n\\import{parts/}{body}\n',
      '/ws/parts/body.tex': '\\subimport{ch1/}{intro}\n',
      '/ws/parts/ch1/intro.tex': '\\input{figure}\n',
      '/ws/parts/ch1/figure.tex': 'fig\n',
    });
    expect(findLatexRoot('/ws/parts/ch1/intro.tex', fs, { workspaceDir: WS }).root).toBe('/ws/main.tex');
    expect(findLatexRoot('/ws/parts/ch1/figure.tex', fs, { workspaceDir: WS }).root).toBe('/ws/main.tex');
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

describe('findLatexRoot: several roots include the file', () => {
  const shared = {
    '/ws/main.tex': '\\documentclass{article}\n\\input{sections/intro}\n',
    '/ws/slides/slides.tex': '\\documentclass{beamer}\n\\input{../sections/intro}\n',
    '/ws/a-notes.tex': '\\documentclass{article}\n\\input{sections/intro}\n',
    '/ws/sections/intro.tex': 'shared\n',
  };

  it('prefers the nearest root, not the alphabetically first', () => {
    const files: Record<string, string> = { ...shared };
    delete files['/ws/a-notes.tex'];
    const r = findLatexRoot('/ws/sections/intro.tex', memFs(files), { workspaceDir: WS });
    expect(r.root).toBe('/ws/main.tex');
    expect(r.reason).toContain('1 other root');
  });

  it('breaks a distance tie by name', () => {
    expect(findLatexRoot('/ws/sections/intro.tex', memFs(shared), { workspaceDir: WS }).root).toBe('/ws/a-notes.tex');
  });

  it('prefers a root whose .fls read the file', () => {
    const fs = memFs(shared, { '/ws/slides/slides.tex': ['/ws/sections/intro.tex'] });
    const r = findLatexRoot('/ws/sections/intro.tex', fs, { workspaceDir: WS });
    expect(r.root).toBe('/ws/slides/slides.tex');
    expect(r.reason).toContain('.fls');
  });

  it('keeps the root this file built with last', () => {
    const fs = memFs(shared, { '/ws/slides/slides.tex': ['/ws/sections/intro.tex'] });
    const r = findLatexRoot('/ws/sections/intro.tex', fs, { workspaceDir: WS, preferredRoot: '/ws/main.tex' });
    expect(r.root).toBe('/ws/main.tex');
  });

  it('finds a root through its .fls when the include is built from a macro', () => {
    const fs = memFs(
      {
        '/ws/main.tex': '\\documentclass{article}\n\\newcommand\\ch{chapters}\n\\input{\\ch/one}\n',
        '/ws/chapters/one.tex': 'one\n',
      },
      { '/ws/main.tex': ['/ws/chapters/one.tex'] },
    );
    expect(findLatexRoot('/ws/chapters/one.tex', fs, { workspaceDir: WS }).root).toBe('/ws/main.tex');
  });
});

describe('parseFlsInputs', () => {
  it('resolves relative INPUT lines against PWD and dedupes', () => {
    const fls = [
      'PWD /ws/paper',
      'INPUT /usr/local/texlive/2026/texmf.cnf',
      'INPUT main.tex',
      'INPUT ./sections/intro.tex',
      'INPUT ./sections/intro.tex',
      'OUTPUT main.aux',
    ].join('\n');
    expect(parseFlsInputs(fls)).toEqual([
      '/usr/local/texlive/2026/texmf.cnf',
      '/ws/paper/main.tex',
      '/ws/paper/sections/intro.tex',
    ]);
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
