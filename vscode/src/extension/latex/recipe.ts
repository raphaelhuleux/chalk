import * as path from 'node:path';

/**
 * Build-step resolution from the user's own LaTeX Workshop configuration
 * (`latex-workshop.latex.recipes` / `.tools` / `.outDir` / `.auxDir` /
 * `.build.fromFolder`), so Chalk-triggered builds behave byte-for-byte like
 * LW's. Placeholder semantics are ported from LW 10.19.0
 * `utils.replaceArgumentPlaceholders` (docker path omitted); keep them in sync
 * if LW ever changes them.
 *
 * Pure: no vscode imports, config objects come in as data.
 */
export interface LwTool {
  name: string;
  command: string;
  args?: string[];
  env?: Record<string, string>;
}

export interface LwRecipe {
  name: string;
  tools: string[];
}

export interface PlaceholderContext {
  /** Absolute path of the LaTeX root file. */
  rootFile: string;
  workspaceDir: string;
  /** `latex-workshop.latex.outDir` raw setting (may itself hold placeholders). */
  outDirSetting: string;
  /** `latex-workshop.latex.auxDir` raw setting; LW's default is `%OUTDIR%`. */
  auxDirSetting?: string;
  /** The directory tools run in — LW's `getWorkingFolder`: the root's own
   *  directory unless `latex.build.fromFolder` moves it. Defaults to the
   *  root's directory. */
  workingDir?: string;
  tmpDir: string;
}

/** LW's default latexmk tool, used when the user has no tool of that name. */
const DEFAULT_LATEXMK: LwTool = {
  name: 'latexmk',
  command: 'latexmk',
  args: ['-synctex=1', '-interaction=nonstopmode', '-file-line-error', '-pdf', '-outdir=%OUTDIR%', '%DOC%'],
};

const DEFAULT_AUXDIR_SETTING = '%OUTDIR%';

const toPosix = (p: string): string => p.split(path.sep).join('/');

/** LW's working folder: `latex.build.fromFolder` relative to the workspace
 *  (or the root's directory when there is no workspace), else the root's
 *  directory. Tools spawn here, and relative out/aux dirs resolve here. */
export function resolveWorkingDir(
  rootFile: string,
  workspaceDir: string | null,
  fromFolderSetting: string | undefined,
): string {
  const rootDir = path.dirname(rootFile);
  if (!fromFolderSetting) return rootDir;
  return path.resolve(workspaceDir ?? rootDir, fromFolderSetting);
}

function workingDirOf(ctx: PlaceholderContext): string {
  return ctx.workingDir ?? path.dirname(ctx.rootFile);
}

function expandBasic(arg: string, ctx: PlaceholderContext): string {
  const parsed = path.parse(ctx.rootFile);
  const dir = toPosix(parsed.dir);
  const doc = toPosix(path.join(parsed.dir, parsed.name));
  const docExt = toPosix(path.join(parsed.dir, parsed.base));
  const ws = toPosix(ctx.workspaceDir);
  const cwd = workingDirOf(ctx);
  return arg
    .replace(/%DOC%/g, doc)
    .replace(/%DOC_W32%/g, doc)
    .replace(/%DOC_EXT%/g, docExt)
    .replace(/%DOC_EXT_W32%/g, docExt)
    .replace(/%DOCFILE_EXT%/g, parsed.base)
    .replace(/%DOCFILE%/g, parsed.name)
    .replace(/%DIR%/g, dir)
    .replace(/%DIR_W32%/g, dir)
    .replace(/%TMPDIR%/g, ctx.tmpDir)
    .replace(/%WORKSPACE_FOLDER%/g, ws)
    .replace(/%RELATIVE_DIR%/, toPosix(path.relative(ctx.workspaceDir, parsed.dir)))
    .replace(/%RELATIVE_DOC%/, toPosix(path.relative(ctx.workspaceDir, path.join(parsed.dir, parsed.name))))
    .replace(/%RELATIVE_CWD_DIR%/, toPosix(path.relative(cwd, parsed.dir)))
    .replace(/%RELATIVE_CWD_DOC%/, toPosix(path.relative(cwd, path.join(parsed.dir, parsed.name))));
}

/** `latex.outDir` gets placeholder-expanded first, then normalized — LW keeps
 *  a relative setting (like "aux") relative, resolved by the tool against cwd. */
export function resolveOutDir(ctx: PlaceholderContext): string {
  return toPosix(path.normalize(expandBasic(ctx.outDirSetting, ctx)));
}

/** `latex.auxDir`, same treatment; its default `%OUTDIR%` makes it follow the
 *  output directory, which is why LW expands `%AUXDIR%` before `%OUTDIR%`. */
export function resolveAuxDir(ctx: PlaceholderContext): string {
  const raw = ctx.auxDirSetting || DEFAULT_AUXDIR_SETTING;
  return toPosix(path.normalize(expandBasic(raw, ctx).replace(/%OUTDIR%/g, resolveOutDir(ctx))));
}

export function expandPlaceholders(arg: string, ctx: PlaceholderContext): string {
  const outDir = resolveOutDir(ctx);
  return expandBasic(arg, ctx)
    .replace(/%AUXDIR%/g, resolveAuxDir(ctx))
    .replace(/%OUTDIR%/g, outDir)
    .replace(/%OUTDIR_W32%/g, outDir);
}

/**
 * Directories a build needs to exist before its first tool runs — LW's
 * `createAuxSubFolders`: pdflatex refuses to write into a missing
 * `-output-directory`, and never creates it. The aux dir itself, plus one
 * subfolder per directory an `\input`/`\include`d file lives in (pdflatex
 * writes `sections/intro.aux` next to the root's aux files). The out dir is
 * added because the PDF lands there. Relative settings resolve against the
 * working directory, as the tool will see them. Absolute paths, deduplicated,
 * in a stable order; the caller skips the ones that already exist.
 */
export function buildDirectories(ctx: PlaceholderContext, includedTexFiles: readonly string[]): string[] {
  const cwd = workingDirOf(ctx);
  const rootDir = path.dirname(ctx.rootFile);
  const auxDir = path.resolve(cwd, resolveAuxDir(ctx));
  const dirs = new Set<string>([path.resolve(cwd, resolveOutDir(ctx)), auxDir]);
  for (const file of includedTexFiles) {
    const relative = path.relative(rootDir, path.dirname(file));
    if (relative.startsWith('..') || path.isAbsolute(relative)) continue;
    dirs.add(path.resolve(auxDir, relative));
  }
  return [...dirs];
}

export interface BuildStep {
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
}

export type StepsResult = { steps: BuildStep[] } | { error: string };

/**
 * LW's `latex.recipe.default`: a recipe name picks that recipe; "first" and
 * "lastUsed" take the first one ("lastUsed" isn't observable from outside
 * LW). No recipes configured means LW's implicit latexmk recipe.
 */
export function resolveBuildSteps(
  recipes: LwRecipe[] | undefined,
  tools: LwTool[] | undefined,
  ctx: PlaceholderContext,
  defaultRecipe = 'first',
): StepsResult {
  const named = recipes?.find((r) => r.name === defaultRecipe);
  const recipe: LwRecipe =
    named ?? (recipes && recipes.length > 0 ? recipes[0] : { name: 'latexmk', tools: ['latexmk'] });
  const steps: BuildStep[] = [];
  for (const toolName of recipe.tools) {
    let tool = tools?.find((t) => t.name === toolName);
    if (!tool && toolName === 'latexmk') tool = DEFAULT_LATEXMK;
    if (!tool) {
      return { error: `recipe "${recipe.name}" references unknown tool "${toolName}"` };
    }
    steps.push({
      name: tool.name,
      command: tool.command,
      args: (tool.args ?? []).map((a) => expandPlaceholders(a, ctx)),
      env: tool.env ?? {},
    });
  }
  if (steps.length === 0) return { error: `recipe "${recipe.name}" has no tools` };
  return { steps };
}

/**
 * Whether a save from Chalk should trigger our build. LW's own build bails
 * whenever the active editor is not a LaTeX TEXT editor (a focused custom
 * editor never is one), and otherwise builds the root of THAT editor. So
 * Chalk builds unless LW will build this same root itself; a second build
 * while one runs is the caller's queue's business.
 */
export interface BuildDecisionInput {
  settingEnabled: boolean;
  lwInstalled: boolean;
  isOpenInChalkTexEditor: boolean;
  /** `latex-workshop.latex.autoBuild.run`: "onSave", "onFileChange" or "never". */
  lwAutoBuildRun: string;
  /** Matched by `latex-workshop.latex.autoBuild.onSave.files.ignore`. */
  ignoredByLw: boolean;
  /** A LaTeX text editor is active and resolves to the saved file's root. */
  lwBuildsSameRoot: boolean;
}

export function shouldBuildOnSave(d: BuildDecisionInput): { build: boolean; reason: string } {
  if (!d.settingEnabled) return { build: false, reason: 'chalk.latex.buildOnSave is off' };
  if (!d.lwInstalled) return { build: false, reason: 'LaTeX Workshop is not installed' };
  if (!d.isOpenInChalkTexEditor) {
    return { build: false, reason: 'saved document is not open in a Chalk editor' };
  }
  if (d.lwAutoBuildRun === 'never') {
    return { build: false, reason: 'latex-workshop.latex.autoBuild.run is "never"' };
  }
  if (d.ignoredByLw) {
    return { build: false, reason: 'matched by latex-workshop.latex.autoBuild.onSave.files.ignore' };
  }
  if (d.lwBuildsSameRoot) {
    return { build: false, reason: 'a LaTeX text editor on the same root is active — LaTeX Workshop builds it' };
  }
  return { build: true, reason: 'LaTeX Workshop cannot build from a Chalk editor' };
}
