import * as vscode from 'vscode';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { WALK_SKIP_DIRS } from '../asset-resolver';
import { texProfile } from '../languages/tex';
import { findLatexRoot, includedTexFiles, type RootFinderFs } from './root-finder';
import {
  buildDirectories,
  resolveBuildSteps,
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
 * even though its autoBuild already knows the root file. Until that guard is
 * relaxed upstream, Chalk fills exactly that gap: on save of a Chalk-open
 * .tex document with no active text editor, resolve the root ourselves and
 * run the user's own LaTeX Workshop recipe. LW's PDF viewer watches the PDF
 * file, so the preview refreshes as usual.
 */

const LW_EXTENSION_ID = 'James-Yu.latex-workshop';
const WALK_MAX_DEPTH = 8;
const WALK_MAX_TEX = 200;
const STEP_TIMEOUT_MS = 10 * 60 * 1000;

function isOpenInChalkTexEditor(uri: vscode.Uri): boolean {
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

/** One view per save: root finding and the aux-dir pass read the same files,
 *  so reads (null results included) are memoized for its lifetime. */
function realFs(workspaceDir: string | null): RootFinderFs {
  const reads = new Map<string, string | null>();
  return {
    readFile: (p) => {
      if (reads.has(p)) return reads.get(p) as string | null;
      let text: string | null;
      try {
        text = readFileSync(p, 'utf8');
      } catch {
        text = null;
      }
      reads.set(p, text);
      return text;
    },
    exists: (p) => existsSync(p),
    listTexFiles: () => (workspaceDir ? listTexFiles(workspaceDir) : []),
  };
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

export function installLatexBuildOnSave(diag: vscode.OutputChannel): vscode.Disposable {
  const channel = vscode.window.createOutputChannel('Chalk LaTeX');
  const building = new Set<string>();

  const saveSub = vscode.workspace.onDidSaveTextDocument((doc) => {
    if (!doc.fileName.endsWith('.tex')) return;

    const cfg = vscode.workspace.getConfiguration('chalk.latex', doc.uri);
    const openInChalk = isOpenInChalkTexEditor(doc.uri);
    const decision = shouldBuildOnSave({
      settingEnabled: cfg.get<boolean>('buildOnSave', true),
      lwInstalled: vscode.extensions.getExtension(LW_EXTENSION_ID) !== undefined,
      isOpenInChalkTexEditor: openInChalk,
      hasActiveTextEditor: vscode.window.activeTextEditor !== undefined,
      alreadyBuilding: building.size > 0,
    });
    if (!decision.build) {
      // Only narrate skips for documents we would otherwise own — anything
      // else is normal text-editor traffic and would spam the log.
      if (openInChalk) {
        channel.appendLine(`[chalk] save of ${path.basename(doc.fileName)}: not building — ${decision.reason}`);
      }
      return;
    }

    const wsFolder = vscode.workspace.getWorkspaceFolder(doc.uri)?.uri.fsPath ?? null;
    const fsView = realFs(wsFolder);
    const { root, reason } = findLatexRoot(doc.fileName, fsView, {
      configuredRoot: cfg.get<string>('rootFile') || null,
      workspaceDir: wsFolder,
    });
    if (!root) {
      channel.appendLine(`[chalk] save of ${path.basename(doc.fileName)}: ${reason}`);
      void vscode.window.setStatusBarMessage('$(warning) Chalk: no LaTeX root found (see Chalk LaTeX log)', 8000);
      return;
    }
    channel.appendLine(`[chalk] building ${root} (root via ${reason})`);

    const lwCfg = vscode.workspace.getConfiguration('latex-workshop', vscode.Uri.file(root));
    const ctx: PlaceholderContext = {
      rootFile: root,
      workspaceDir: wsFolder ?? path.dirname(root),
      outDirSetting: lwCfg.get<string>('latex.outDir', '%DIR%'),
      auxDirSetting: lwCfg.get<string>('latex.auxDir', '%OUTDIR%'),
      workingDir: resolveWorkingDir(root, wsFolder, lwCfg.get<string>('latex.build.fromFolder', '')),
      tmpDir: os.tmpdir(),
    };
    const resolved = resolveBuildSteps(
      lwCfg.get<LwRecipe[]>('latex.recipes'),
      lwCfg.get<LwTool[]>('latex.tools'),
      ctx,
    );
    if ('error' in resolved) {
      channel.appendLine(`[chalk] cannot build: ${resolved.error}`);
      void vscode.window.setStatusBarMessage('$(error) Chalk: LaTeX recipe error (see Chalk LaTeX log)', 8000);
      return;
    }

    // LW pre-creates the aux tree (`createAuxSubFolders`) because pdflatex
    // will not write into a missing -output-directory. Mirror it, or a fresh
    // clone with `-output-directory=%DIR%/.build` fails on its first save.
    for (const dir of buildDirectories(ctx, includedTexFiles(root, fsView))) {
      if (existsSync(dir)) continue;
      try {
        mkdirSync(dir, { recursive: true });
        channel.appendLine(`[chalk] created ${dir}`);
      } catch (e) {
        channel.appendLine(`[chalk] could not create ${dir}: ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    const cwd = ctx.workingDir ?? path.dirname(root);
    building.add(root);
    const spinner = vscode.window.setStatusBarMessage(`$(sync~spin) Chalk: building ${path.basename(root)}…`);
    void (async () => {
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
        diag.appendLine(`[chalk] latex build crashed: ${msg}`);
      } finally {
        building.delete(root);
        spinner.dispose();
      }
    })();
  });

  return vscode.Disposable.from(saveSub, channel);
}
