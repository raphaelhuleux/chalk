import * as vscode from 'vscode';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { WALK_SKIP_DIRS } from '../asset-resolver';
import { texProfile } from '../languages/tex';
import { BuildQueue } from './build-queue';
import {
  findLatexRoot,
  includedTexFiles,
  parseFlsInputs,
  type RootFinderFs,
  type RootResult,
} from './root-finder';
import {
  buildDirectories,
  resolveAuxDir,
  resolveBuildSteps,
  resolveOutDir,
  resolveWorkingDir,
  shouldBuildOnSave,
  type BuildStep,
  type LwRecipe,
  type LwTool,
  type PlaceholderContext,
} from './recipe';

/**
 * Build-on-save for .tex documents edited in Chalk.
 *
 * LaTeX Workshop's build() refuses to run when `vscode.window.activeTextEditor`
 * is undefined — which it always is while a custom editor (Chalk) has focus —
 * and otherwise builds the root of whatever text editor is active. Until that
 * guard is relaxed upstream, Chalk fills the gap: on save of a Chalk-open
 * .tex document, resolve the root ourselves and run the user's own LaTeX
 * Workshop recipe. LW's PDF viewer watches the PDF file, so the preview
 * refreshes as usual.
 */

export const LW_EXTENSION_ID = 'James-Yu.latex-workshop';
/** LW's `hasLaTeXLangId`: documents LW's own build treats as LaTeX. */
const LW_LATEX_LANG_IDS = new Set(['latex', 'context', 'latex-expl3', 'pweave', 'jlweave', 'rsweave', 'doctex']);
const WALK_MAX_DEPTH = 8;
const WALK_MAX_TEX = 200;
/** Without a workspace folder, roots are searched this many folders above
 *  the saved file (a chapter usually sits one level under its root). */
const LOOSE_FILE_WALK_UP = 2;
const STEP_TIMEOUT_MS = 10 * 60 * 1000;

export function isOpenInChalkTexEditor(uri: vscode.Uri): boolean {
  const key = uri.toString();
  return vscode.window.tabGroups.all.some((group) =>
    group.tabs.some(
      (tab) =>
        tab.input instanceof vscode.TabInputCustom &&
        tab.input.viewType === texProfile.viewType &&
        tab.input.uri.toString() === key,
    ),
  );
}

/** Bounded synchronous workspace walk; only runs on an actual build attempt. */
function listTexFiles(rootDir: string): string[] {
  const found: string[] = [];
  const walk = (dir: string, depth: number): void => {
    if (depth > WALK_MAX_DEPTH || found.length >= WALK_MAX_TEX) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (found.length >= WALK_MAX_TEX) return;
      if (entry.isDirectory()) {
        if (!WALK_SKIP_DIRS.has(entry.name) && !entry.name.startsWith('.')) {
          walk(path.join(dir, entry.name), depth + 1);
        }
      } else if (entry.isFile() && entry.name.endsWith('.tex')) {
        found.push(path.join(dir, entry.name));
      }
    }
  };
  walk(rootDir, 0);
  return found;
}

function readOrNull(p: string): string | null {
  try {
    return readFileSync(p, 'utf8');
  } catch {
    return null;
  }
}

function runStep(step: BuildStep, cwd: string, channel: vscode.OutputChannel): Promise<number> {
  return new Promise((resolve) => {
    channel.appendLine(`[chalk] $ ${step.command} ${step.args.join(' ')}  (cwd: ${cwd})`);
    const child = spawn(step.command, step.args, {
      cwd,
      // max_print_line mirrors LW: keeps latexmk from hard-wrapping log lines.
      env: { ...process.env, ...step.env, max_print_line: '10000' },
    });
    const timer = setTimeout(() => {
      channel.appendLine(`[chalk] ${step.name} timed out after ${STEP_TIMEOUT_MS / 60000} min — killing.`);
      child.kill();
    }, STEP_TIMEOUT_MS);
    child.stdout.on('data', (d: Buffer) => channel.append(d.toString()));
    child.stderr.on('data', (d: Buffer) => channel.append(d.toString()));
    child.on('error', (e) => {
      clearTimeout(timer);
      channel.appendLine(`[chalk] failed to spawn ${step.command}: ${e.message}`);
      resolve(-1);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve(code ?? -1);
    });
  });
}

/** Root resolution, the per-root build queue and output paths, shared by
 *  build-on-save and the `chalk.latex.*` commands. */
export class LatexBuilder implements vscode.Disposable {
  readonly channel = vscode.window.createOutputChannel('Chalk LaTeX');
  private readonly queue = new BuildQueue((root) => this.runBuild(root));
  /** Saved file → the root it last built, for `preferredRoot`. */
  private readonly lastRoot = new Map<string, string>();
  /** Documents `buildNow` is saving itself; their save must not build twice. */
  private readonly manualSaves = new Set<string>();
  private readonly saveSub: vscode.Disposable;

  constructor(private readonly diag: vscode.OutputChannel) {
    this.saveSub = vscode.workspace.onDidSaveTextDocument((doc) => this.onSave(doc));
  }

  dispose(): void {
    this.saveSub.dispose();
    this.channel.dispose();
  }

  /** One file-system view per resolution: root finding, the `.fls` probes and
   *  the aux-dir pass read the same files, so reads are memoized. */
  private fsView(filePath: string, wsFolder: string | null): RootFinderFs {
    const reads = new Map<string, string | null>();
    const readFile = (p: string): string | null => {
      if (!reads.has(p)) reads.set(p, readOrNull(p));
      return reads.get(p) as string | null;
    };
    const walkRoot = wsFolder ?? path.resolve(path.dirname(filePath), ...Array(LOOSE_FILE_WALK_UP).fill('..'));
    return {
      readFile,
      exists: (p) => existsSync(p),
      listTexFiles: () => listTexFiles(walkRoot),
      flsInputs: (root) => {
        const ctx = this.contextFor(root, wsFolder);
        const cwd = ctx.workingDir ?? path.dirname(root);
        const name = `${path.parse(root).name}.fls`;
        for (const dir of new Set([resolveAuxDir(ctx), resolveOutDir(ctx), '.'])) {
          const fls = readFile(path.resolve(cwd, dir, name));
          if (fls !== null) return parseFlsInputs(fls);
        }
        return [];
      },
    };
  }

  private static workspaceDirOf(filePath: string): string | null {
    return vscode.workspace.getWorkspaceFolder(vscode.Uri.file(filePath))?.uri.fsPath ?? null;
  }

  resolveRoot(filePath: string): RootResult {
    const wsFolder = LatexBuilder.workspaceDirOf(filePath);
    const cfg = vscode.workspace.getConfiguration('chalk.latex', vscode.Uri.file(filePath));
    return findLatexRoot(filePath, this.fsView(filePath, wsFolder), {
      configuredRoot: cfg.get<string>('rootFile') || null,
      workspaceDir: wsFolder,
      preferredRoot: this.lastRoot.get(path.resolve(filePath)) ?? null,
    });
  }

  private contextFor(root: string, wsFolder: string | null): PlaceholderContext {
    const lwCfg = vscode.workspace.getConfiguration('latex-workshop', vscode.Uri.file(root));
    return {
      rootFile: root,
      workspaceDir: wsFolder ?? path.dirname(root),
      outDirSetting: lwCfg.get<string>('latex.outDir', '%DIR%'),
      auxDirSetting: lwCfg.get<string>('latex.auxDir', '%OUTDIR%'),
      workingDir: resolveWorkingDir(root, wsFolder, lwCfg.get<string>('latex.build.fromFolder', '')),
      tmpDir: os.tmpdir(),
    };
  }

  /** Where the recipe leaves `root`'s PDF: LW's `getPdfPath`. */
  pdfPath(root: string): string {
    const ctx = this.contextFor(root, LatexBuilder.workspaceDirOf(root));
    return path.resolve(ctx.workingDir ?? path.dirname(root), resolveOutDir(ctx), `${path.parse(root).name}.pdf`);
  }

  /** Resolve `filePath`'s root (unless already resolved) and queue its
   *  build. Null when no root. */
  buildFor(filePath: string, resolved: RootResult = this.resolveRoot(filePath)): string | null {
    const { root, reason } = resolved;
    if (!root) {
      this.channel.appendLine(`[chalk] ${path.basename(filePath)}: ${reason}`);
      void vscode.window.setStatusBarMessage('$(warning) Chalk: no LaTeX root found (see Chalk LaTeX log)', 8000);
      return null;
    }
    this.lastRoot.set(path.resolve(filePath), root);
    const state = this.queue.request(root);
    this.channel.appendLine(
      state === 'started'
        ? `[chalk] building ${root} (root via ${reason})`
        : `[chalk] ${path.basename(root)} is building — queued one more build for the save of ${path.basename(filePath)}`,
    );
    return root;
  }

  /** The `chalk.latex.build` command: save if dirty, then build whatever
   *  the build-on-save settings say. */
  async buildNow(doc: vscode.TextDocument): Promise<string | null> {
    if (doc.isDirty) {
      const key = doc.uri.toString();
      this.manualSaves.add(key);
      try {
        await doc.save();
      } finally {
        this.manualSaves.delete(key);
      }
    }
    return this.buildFor(doc.fileName);
  }

  isBuilding(root: string): boolean {
    return this.queue.isBuilding(root);
  }

  idle(root: string): Promise<void> {
    return this.queue.idle(root);
  }

  /** Would LW's own autoBuild take this save? Only when a LaTeX text editor
   *  is active and resolves to the same root (see shouldBuildOnSave). */
  private lwBuildsSameRoot(savedRoot: string | null): boolean {
    const active = vscode.window.activeTextEditor?.document;
    if (!active || active.uri.scheme !== 'file' || !LW_LATEX_LANG_IDS.has(active.languageId)) return false;
    return savedRoot !== null && this.resolveRoot(active.fileName).root === savedRoot;
  }

  private onSave(doc: vscode.TextDocument): void {
    if (!doc.fileName.endsWith('.tex') || doc.uri.scheme !== 'file') return;
    if (this.manualSaves.has(doc.uri.toString())) return;
    const openInChalk = isOpenInChalkTexEditor(doc.uri);
    // Only narrate decisions for documents we would otherwise own — anything
    // else is normal text-editor traffic and would spam the log.
    if (!openInChalk) return;

    const cfg = vscode.workspace.getConfiguration('chalk.latex', doc.uri);
    const lwCfg = vscode.workspace.getConfiguration('latex-workshop', doc.uri);
    const ignoreGlobs = lwCfg.get<string[]>('latex.autoBuild.onSave.files.ignore', []);
    const cheap = {
      settingEnabled: cfg.get<boolean>('buildOnSave', true),
      lwInstalled: vscode.extensions.getExtension(LW_EXTENSION_ID) !== undefined,
      isOpenInChalkTexEditor: openInChalk,
      lwAutoBuildRun: lwCfg.get<string>('latex.autoBuild.run', 'onFileChange'),
      ignoredByLw: ignoreGlobs.some((pattern) => vscode.languages.match({ pattern }, doc) > 0),
    };
    // Root resolution walks the workspace, so it runs only once the cheap
    // checks pass.
    const early = shouldBuildOnSave({ ...cheap, lwBuildsSameRoot: false });
    if (!early.build) {
      this.channel.appendLine(`[chalk] save of ${path.basename(doc.fileName)}: not building — ${early.reason}`);
      return;
    }
    const resolved = this.resolveRoot(doc.fileName);
    const decision = shouldBuildOnSave({ ...cheap, lwBuildsSameRoot: this.lwBuildsSameRoot(resolved.root) });
    if (!decision.build) {
      this.channel.appendLine(`[chalk] save of ${path.basename(doc.fileName)}: not building — ${decision.reason}`);
      return;
    }
    this.buildFor(doc.fileName, resolved);
  }

  /** One full recipe run. Settings are re-read per run, so a queued rerun
   *  picks up a recipe edited meanwhile. */
  private async runBuild(root: string): Promise<void> {
    const channel = this.channel;
    const wsFolder = LatexBuilder.workspaceDirOf(root);
    const ctx = this.contextFor(root, wsFolder);
    const lwCfg = vscode.workspace.getConfiguration('latex-workshop', vscode.Uri.file(root));
    const resolved = resolveBuildSteps(
      lwCfg.get<LwRecipe[]>('latex.recipes'),
      lwCfg.get<LwTool[]>('latex.tools'),
      ctx,
      lwCfg.get<string>('latex.recipe.default', 'first'),
    );
    if ('error' in resolved) {
      channel.appendLine(`[chalk] cannot build: ${resolved.error}`);
      void vscode.window.setStatusBarMessage('$(error) Chalk: LaTeX recipe error (see Chalk LaTeX log)', 8000);
      return;
    }

    // LW pre-creates the aux tree (`createAuxSubFolders`) because pdflatex
    // will not write into a missing -output-directory. Mirror it, or a fresh
    // clone with `-output-directory=%DIR%/.build` fails on its first save.
    for (const dir of buildDirectories(ctx, includedTexFiles(root, this.fsView(root, wsFolder)))) {
      if (existsSync(dir)) continue;
      try {
        mkdirSync(dir, { recursive: true });
        channel.appendLine(`[chalk] created ${dir}`);
      } catch (e) {
        channel.appendLine(`[chalk] could not create ${dir}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    const cwd = ctx.workingDir ?? path.dirname(root);
    const spinner = vscode.window.setStatusBarMessage(`$(sync~spin) Chalk: building ${path.basename(root)}…`);
    try {
      for (const step of resolved.steps) {
        const code = await runStep(step, cwd, channel);
        if (code !== 0) {
          channel.appendLine(`[chalk] ${step.name} exited with ${code} — build stopped.`);
          void vscode.window.setStatusBarMessage('$(error) Chalk: LaTeX build failed (see Chalk LaTeX log)', 8000);
          return;
        }
      }
      channel.appendLine(`[chalk] build succeeded: ${path.basename(root)}`);
      void vscode.window.setStatusBarMessage(`$(check) Chalk: built ${path.basename(root)}`, 5000);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      this.diag.appendLine(`[chalk] latex build crashed: ${msg}`);
    } finally {
      spinner.dispose();
    }
  }
}
