import { describe, expect, it } from 'vitest';
import {
  buildDirectories,
  expandPlaceholders,
  resolveAuxDir,
  resolveBuildSteps,
  resolveOutDir,
  resolveWorkingDir,
  shouldBuildOnSave,
  type PlaceholderContext,
} from '../../src/extension/latex/recipe';

const ctx: PlaceholderContext = {
  rootFile: '/ws/paper/article/main.tex',
  workspaceDir: '/ws',
  outDirSetting: 'aux',
  tmpDir: '/tmp/x',
};

describe('expandPlaceholders (LW 10.19.0 semantics)', () => {
  it.each([
    ['%DOC%', '/ws/paper/article/main'],
    ['%DOC_EXT%', '/ws/paper/article/main.tex'],
    ['%DOCFILE%', 'main'],
    ['%DOCFILE_EXT%', 'main.tex'],
    ['%DIR%', '/ws/paper/article'],
    ['%TMPDIR%', '/tmp/x'],
    ['%WORKSPACE_FOLDER%', '/ws'],
    ['%RELATIVE_DIR%', 'paper/article'],
    ['%RELATIVE_DOC%', 'paper/article/main'],
    ['%OUTDIR%', 'aux'],
    ['%OUTDIR_W32%', 'aux'],
    ['%AUXDIR%', 'aux'],
    ['%RELATIVE_CWD_DIR%', ''],
    ['%RELATIVE_CWD_DOC%', 'main'],
  ])('%s -> %s', (arg, expected) => {
    expect(expandPlaceholders(arg, ctx)).toBe(expected);
  });

  it('expands the user latexmk args exactly like LW', () => {
    const args = ['-synctex=1', '-interaction=nonstopmode', '-file-line-error', '-pdf', '-outdir=%OUTDIR%', '%DOCFILE%'];
    expect(args.map((a) => expandPlaceholders(a, ctx))).toEqual([
      '-synctex=1',
      '-interaction=nonstopmode',
      '-file-line-error',
      '-pdf',
      '-outdir=aux',
      'main',
    ]);
  });

  it('keeps a relative outDir relative and expands %DIR% inside it', () => {
    expect(resolveOutDir(ctx)).toBe('aux');
    expect(resolveOutDir({ ...ctx, outDirSetting: '%DIR%/out' })).toBe('/ws/paper/article/out');
    expect(resolveOutDir({ ...ctx, outDirSetting: '%DIR%' })).toBe('/ws/paper/article');
  });

  it('auxDir defaults to the out dir and honours its own setting', () => {
    expect(resolveAuxDir(ctx)).toBe('aux');
    expect(resolveAuxDir({ ...ctx, auxDirSetting: '%DIR%/.build' })).toBe('/ws/paper/article/.build');
    expect(resolveAuxDir({ ...ctx, auxDirSetting: '%OUTDIR%/aux' })).toBe('aux/aux');
    expect(expandPlaceholders('-auxdir=%AUXDIR%', { ...ctx, auxDirSetting: '%DIR%/.build' })).toBe(
      '-auxdir=/ws/paper/article/.build',
    );
  });

  it('expands a pdflatex + bibtex + movepdf tool set writing into %DIR%/.build', () => {
    const c = { ...ctx, outDirSetting: '%DIR%', auxDirSetting: '%DIR%/.build' };
    expect(expandPlaceholders('-output-directory=%DIR%/.build', c)).toBe('-output-directory=/ws/paper/article/.build');
    expect(expandPlaceholders('%DIR%/.build/%DOCFILE%', c)).toBe('/ws/paper/article/.build/main');
    expect(expandPlaceholders('mv -f ".build/%DOCFILE%.pdf" .', c)).toBe('mv -f ".build/main.pdf" .');
  });

  it('relative CWD placeholders follow latex.build.fromFolder', () => {
    const c = { ...ctx, workingDir: '/ws' };
    expect(expandPlaceholders('%RELATIVE_CWD_DIR%', c)).toBe('paper/article');
    expect(expandPlaceholders('%RELATIVE_CWD_DOC%', c)).toBe('paper/article/main');
  });
});

describe('resolveWorkingDir', () => {
  it('is the root directory unless latex.build.fromFolder moves it', () => {
    expect(resolveWorkingDir('/ws/paper/main.tex', '/ws', '')).toBe('/ws/paper');
    expect(resolveWorkingDir('/ws/paper/main.tex', '/ws', undefined)).toBe('/ws/paper');
    expect(resolveWorkingDir('/ws/paper/main.tex', '/ws', 'build')).toBe('/ws/build');
    expect(resolveWorkingDir('/ws/paper/main.tex', null, 'build')).toBe('/ws/paper/build');
  });
});

describe('buildDirectories', () => {
  it('lists the out dir, the aux dir and one aux subfolder per included file directory', () => {
    const c = { ...ctx, outDirSetting: '%DIR%', auxDirSetting: '%DIR%/.build' };
    expect(
      buildDirectories(c, [
        '/ws/paper/article/main.tex',
        '/ws/paper/article/sections/intro.tex',
        '/ws/paper/article/sections/method.tex',
        '/ws/paper/shared/macros.tex',
      ]),
    ).toEqual(['/ws/paper/article', '/ws/paper/article/.build', '/ws/paper/article/.build/sections']);
  });

  it('resolves a relative aux dir against the working directory', () => {
    expect(buildDirectories(ctx, ['/ws/paper/article/main.tex'])).toEqual(['/ws/paper/article/aux']);
    expect(buildDirectories({ ...ctx, workingDir: '/ws' }, [])).toEqual(['/ws/aux']);
  });
});

describe('resolveBuildSteps', () => {
  const userTools = [
    {
      name: 'latexmk',
      command: 'latexmk',
      args: ['-pdf', '-outdir=%OUTDIR%', '%DOCFILE%'],
      env: {},
    },
    { name: 'bibtex', command: 'bibtex', args: ['%DOCFILE%'] },
  ];

  it('uses the first recipe and resolves tools by name', () => {
    const r = resolveBuildSteps(
      [
        { name: 'latexmk 🔃', tools: ['latexmk'] },
        { name: 'full', tools: ['latexmk', 'bibtex', 'latexmk'] },
      ],
      userTools,
      ctx,
    );
    expect('steps' in r && r.steps.map((s) => s.name)).toEqual(['latexmk']);
    expect('steps' in r && r.steps[0].args).toEqual(['-pdf', '-outdir=aux', 'main']);
  });

  it('falls back to the implicit latexmk recipe when none are configured', () => {
    const r = resolveBuildSteps(undefined, undefined, ctx);
    expect('steps' in r && r.steps[0].command).toBe('latexmk');
    expect('steps' in r && r.steps[0].args).toContain('/ws/paper/article/main');
  });

  it('honours latex.recipe.default when it names a recipe', () => {
    const recipes = [
      { name: 'latexmk', tools: ['latexmk'] },
      { name: 'full', tools: ['latexmk', 'bibtex', 'latexmk'] },
    ];
    const named = resolveBuildSteps(recipes, userTools, ctx, 'full');
    expect('steps' in named && named.steps.map((s) => s.name)).toEqual(['latexmk', 'bibtex', 'latexmk']);
    for (const fallback of ['first', 'lastUsed', 'no such recipe']) {
      const r = resolveBuildSteps(recipes, userTools, ctx, fallback);
      expect('steps' in r && r.steps.map((s) => s.name)).toEqual(['latexmk']);
    }
  });

  it('errors on an unknown tool name', () => {
    const r = resolveBuildSteps([{ name: 'weird', tools: ['tectonic'] }], userTools, ctx);
    expect('error' in r && r.error).toContain('tectonic');
  });
});

describe('shouldBuildOnSave', () => {
  const yes = {
    settingEnabled: true,
    lwInstalled: true,
    isOpenInChalkTexEditor: true,
    lwAutoBuildRun: 'onFileChange',
    ignoredByLw: false,
    lwBuildsSameRoot: false,
  };

  it('builds a Chalk save that LaTeX Workshop cannot', () => {
    expect(shouldBuildOnSave(yes).build).toBe(true);
    expect(shouldBuildOnSave({ ...yes, lwAutoBuildRun: 'onSave' }).build).toBe(true);
  });

  it.each([
    ['settingEnabled', { ...yes, settingEnabled: false }],
    ['lwInstalled', { ...yes, lwInstalled: false }],
    ['isOpenInChalkTexEditor', { ...yes, isOpenInChalkTexEditor: false }],
    ['autoBuild.run never', { ...yes, lwAutoBuildRun: 'never' }],
    ['ignore glob', { ...yes, ignoredByLw: true }],
    ['LW builds the same root', { ...yes, lwBuildsSameRoot: true }],
  ])('skips when %s says so', (_name, input) => {
    const d = shouldBuildOnSave(input);
    expect(d.build).toBe(false);
    expect(d.reason).not.toBe('');
  });
});
