import * as path from 'node:path';

/**
 * LaTeX root-file resolution for build-on-save, needed because LaTeX
 * Workshop's own root state isn't queryable from another extension. Pure
 * logic over an injected file-system view so it unit-tests without disk.
 *
 * Resolution order (first hit wins):
 *   1. `% !TEX root = …` magic comment in the saved file (TeXShop convention,
 *      also honored by LaTeX Workshop) — author intent, beats everything.
 *   2. `chalk.latex.rootFile` setting.
 *   3. The saved file itself, when it declares `\documentclass`.
 *   4. Include-graph scan: any workspace .tex with `\documentclass` whose
 *      transitive `\input`/`\include`/`\subfile`/`\import` closure reaches
 *      the saved file. LaTeX resolves include paths against the COMPILE
 *      directory (the root's dir), so the scan does too.
 */
export interface RootFinderFs {
  /** UTF-8 contents, or null when unreadable. */
  readFile(absPath: string): string | null;
  exists(absPath: string): boolean;
  /** Absolute paths of workspace .tex files (caller bounds the walk). */
  listTexFiles(): string[];
}

export interface RootFinderOptions {
  /** chalk.latex.rootFile — absolute, or relative to workspaceDir. */
  configuredRoot?: string | null;
  workspaceDir?: string | null;
}

export interface RootResult {
  root: string | null;
  /** Human-readable trace for the output channel. */
  reason: string;
}

const MAGIC_ROOT = /^\s*%\s*!\s*TEX\s+root\s*=\s*(.+?)\s*$/i;
const MAGIC_SCAN_LINES = 15;
/** Include-graph safety bound; a paper project is a handful of files. */
const MAX_GRAPH_FILES = 200;

/** Drop `%` comments (but keep escaped `\%`) so commented-out
 *  `\documentclass`/`\input` lines don't count. */
export function stripComments(tex: string): string {
  return tex
    .split('\n')
    .map((line) => {
      const m = /(^|[^\\])%/.exec(line);
      return m ? line.slice(0, m.index + m[1].length) : line;
    })
    .join('\n');
}

function hasDocumentclass(tex: string): boolean {
  return /\\documentclass/.test(stripComments(tex));
}

/** Resolve an include target the way TeX does: against the root's directory,
 *  with `.tex` appended when no extension is given. */
function resolveInclude(rootDir: string, target: string): string {
  const withExt = path.extname(target) === '' ? `${target}.tex` : target;
  return path.resolve(rootDir, withExt);
}

function includesOf(tex: string, rootDir: string): string[] {
  const stripped = stripComments(tex);
  const out: string[] = [];
  for (const m of stripped.matchAll(/\\(?:input|include|subfile)\s*\{([^}]+)\}/g)) {
    out.push(resolveInclude(rootDir, m[1].trim()));
  }
  for (const m of stripped.matchAll(/\\import\s*\{([^}]+)\}\s*\{([^}]+)\}/g)) {
    out.push(resolveInclude(rootDir, path.join(m[1].trim(), m[2].trim())));
  }
  return out;
}

/**
 * BFS over `rootFile`'s `\input`/`\include`/`\subfile`/`\import` closure:
 * each file the file system can read, with its resolved include targets
 * (readable or not). Bounded by MAX_GRAPH_FILES visited paths.
 */
function* includeClosure(
  rootFile: string,
  fs: RootFinderFs,
): Generator<{ file: string; includes: string[] }> {
  const root = path.resolve(rootFile);
  const rootDir = path.dirname(root);
  const queue = [root];
  const visited = new Set<string>();
  while (queue.length > 0 && visited.size < MAX_GRAPH_FILES) {
    const current = queue.shift() as string;
    if (visited.has(current)) continue;
    visited.add(current);
    const content = fs.readFile(current);
    if (content === null) continue;
    const includes = includesOf(content, rootDir);
    yield { file: current, includes };
    for (const inc of includes) {
      if (!visited.has(inc)) queue.push(inc);
    }
  }
}

/** True if `rootFile`'s include graph names `target`, even when `target`
 *  itself is unreadable. */
function graphReaches(rootFile: string, target: string, fs: RootFinderFs): boolean {
  for (const { includes } of includeClosure(rootFile, fs)) {
    if (includes.includes(target)) return true;
  }
  return false;
}

/**
 * The root plus every .tex file its include closure reaches and the file
 * system can read: LW's `getIncludedTeX`, used to pre-create one aux
 * subfolder per included file's directory before a build.
 */
export function includedTexFiles(rootFile: string, fs: RootFinderFs): string[] {
  return Array.from(includeClosure(rootFile, fs), ({ file }) => file);
}

export function findLatexRoot(
  savedPath: string,
  fs: RootFinderFs,
  opts: RootFinderOptions = {},
): RootResult {
  const saved = path.resolve(savedPath);
  const savedContent = fs.readFile(saved);

  // 1. Magic comment.
  if (savedContent !== null) {
    for (const line of savedContent.split('\n', MAGIC_SCAN_LINES)) {
      const m = MAGIC_ROOT.exec(line);
      if (!m) continue;
      const target = m[1];
      for (const candidate of [target, `${target}.tex`]) {
        const abs = path.resolve(path.dirname(saved), candidate);
        if (fs.exists(abs)) {
          return { root: abs, reason: `magic comment in ${path.basename(saved)}` };
        }
      }
      return { root: null, reason: `magic comment points at missing file: ${target}` };
    }
  }

  // 2. Explicit setting.
  if (opts.configuredRoot) {
    const abs = path.isAbsolute(opts.configuredRoot)
      ? opts.configuredRoot
      : path.resolve(opts.workspaceDir ?? path.dirname(saved), opts.configuredRoot);
    if (fs.exists(abs)) {
      return { root: abs, reason: 'chalk.latex.rootFile setting' };
    }
    return { root: null, reason: `chalk.latex.rootFile does not exist: ${abs}` };
  }

  // 3. The saved file is itself a root.
  if (savedContent !== null && hasDocumentclass(savedContent)) {
    return { root: saved, reason: '\\documentclass in the saved file' };
  }

  // 4. Include-graph scan.
  const candidates = fs
    .listTexFiles()
    .map((p) => path.resolve(p))
    .filter((p) => p !== saved)
    .sort();
  for (const candidate of candidates) {
    const content = fs.readFile(candidate);
    if (content === null || !hasDocumentclass(content)) continue;
    if (graphReaches(candidate, saved, fs)) {
      return { root: candidate, reason: `include graph from ${path.basename(candidate)}` };
    }
  }

  return { root: null, reason: 'no root found (no magic comment, setting, \\documentclass, or including root)' };
}
