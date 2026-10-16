import * as path from 'node:path';

/**
 * LaTeX root-file resolution for build-on-save, needed because LaTeX
 * Workshop's own root state isn't queryable from another extension. Pure
 * logic over an injected file-system view so it unit-tests without disk.
 *
 * Resolution order (first hit wins):
 *   1. `% !TEX root = …` magic comment anywhere in the saved file (TeXShop
 *      convention, also honored by LaTeX Workshop): author intent.
 *   2. `chalk.latex.rootFile` setting.
 *   3. The saved file itself, when it declares `\documentclass`.
 *   4. Workspace roots (`\documentclass` files) that reach the saved file,
 *      through their include graph or their latest `.fls` recorder file.
 *      When several do, see `rankRoots`.
 */
export interface RootFinderFs {
  /** UTF-8 contents, or null when unreadable. */
  readFile(absPath: string): string | null;
  exists(absPath: string): boolean;
  /** Absolute paths of workspace .tex files (caller bounds the walk). */
  listTexFiles(): string[];
  /** Absolute input paths from `rootFile`'s last `.fls`, or [] when there is
   *  none. Catches includes the regex scan cannot see (`\input{\dir/x}`). */
  flsInputs?(rootFile: string): string[];
}

export interface RootFinderOptions {
  /** chalk.latex.rootFile — absolute, or relative to workspaceDir. */
  configuredRoot?: string | null;
  workspaceDir?: string | null;
  /** The root this file last built with this session; wins a tie between
   *  several roots so the choice does not flip between saves. */
  preferredRoot?: string | null;
}

export interface RootResult {
  root: string | null;
  /** Human-readable trace for the output channel. */
  reason: string;
}

const MAGIC_ROOT = /^\s*%\s*!\s*TEX\s+root\s*=\s*(.+?)\s*$/i;
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

function withTexExt(target: string): string {
  return path.extname(target) === '' ? `${target}.tex` : target;
}

/**
 * A file in the include graph with the directory its own includes resolve
 * against. TeX looks in the compile directory (the root's) first; the
 * `import` package and `subfiles` add the imported file's directory, so
 * includes inside those resolve against both.
 */
interface GraphNode {
  file: string;
  base: string;
}

/** `\input`-family targets resolve against the root dir, then the node's
 *  import base when that differs. */
function inputTargets(target: string, node: GraphNode, rootDir: string): GraphNode[] {
  const rel = withTexExt(target.trim());
  const bases = node.base === rootDir ? [rootDir] : [rootDir, node.base];
  return bases.map((b) => ({ file: path.resolve(b, rel), base: node.base }));
}

function includesOf(tex: string, node: GraphNode, rootDir: string): GraphNode[] {
  const stripped = stripComments(tex);
  const out: GraphNode[] = [];
  // Braced and TeX-primitive (`\input chapters/one`) forms.
  for (const m of stripped.matchAll(
    /\\(?:input|include|InputIfFileExists)\s*(?:\{([^}]+)\}|\s([^\s{}%\\]+))/g,
  )) {
    out.push(...inputTargets(m[1] ?? m[2], node, rootDir));
  }
  for (const m of stripped.matchAll(/\\subfile\s*\{([^}]+)\}/g)) {
    for (const t of inputTargets(m[1], node, rootDir)) {
      out.push({ file: t.file, base: path.dirname(t.file) });
    }
  }
  // `import` package: \import{dir}{file} takes dir from the compile
  // directory; \subimport{dir}{file} from the current file's base.
  for (const m of stripped.matchAll(
    /\\(sub)?(?:import|inputfrom|includefrom)\*?\s*\{([^}]*)\}\s*\{([^}]+)\}/g,
  )) {
    const dir = path.resolve(m[1] ? node.base : rootDir, m[2].trim());
    out.push({ file: path.resolve(dir, withTexExt(m[3].trim())), base: dir });
  }
  return out;
}

/**
 * BFS over `rootFile`'s include closure: each file the file system can read,
 * with its resolved include targets (readable or not). Bounded by
 * MAX_GRAPH_FILES visited paths.
 */
function* includeClosure(
  rootFile: string,
  fs: RootFinderFs,
): Generator<{ file: string; includes: string[] }> {
  const root = path.resolve(rootFile);
  const rootDir = path.dirname(root);
  const queue: GraphNode[] = [{ file: root, base: rootDir }];
  const visited = new Set<string>();
  while (queue.length > 0 && visited.size < MAX_GRAPH_FILES) {
    const node = queue.shift() as GraphNode;
    if (visited.has(node.file)) continue;
    visited.add(node.file);
    const content = fs.readFile(node.file);
    if (content === null) continue;
    const children = includesOf(content, node, rootDir);
    yield { file: node.file, includes: children.map((c) => c.file) };
    for (const child of children) {
      if (!visited.has(child.file)) queue.push(child);
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

/**
 * `INPUT` lines of a `.fls` recorder file as absolute paths. Relative ones
 * resolve against its `PWD` line, which latexmk and pdflatex both write.
 */
export function parseFlsInputs(fls: string): string[] {
  let pwd = '';
  const inputs = new Set<string>();
  for (const line of fls.split(/\r?\n/)) {
    if (line.startsWith('PWD ')) pwd = line.slice(4).trim();
    else if (line.startsWith('INPUT ')) {
      const p = line.slice(6).trim();
      inputs.add(path.isAbsolute(p) || !pwd ? path.resolve(p) : path.resolve(pwd, p));
    }
  }
  return [...inputs];
}

/** Directory hops from `root`'s folder to `saved`'s: a sibling is 0, a file
 *  in `sections/` is 1. */
function distance(root: string, saved: string): number {
  const rel = path.relative(path.dirname(root), path.dirname(saved));
  return rel === '' ? 0 : rel.split(path.sep).length;
}

/**
 * Order between several roots that all reach the saved file (a shared
 * chapter in `main.tex` and `slides.tex`): this session's previous choice,
 * then a root whose last compile actually read the file, then the nearest
 * folder, then name.
 */
function rankRoots(
  roots: { file: string; viaFls: boolean }[],
  saved: string,
  preferred: string | null,
): { file: string; viaFls: boolean }[] {
  const key = (r: { file: string; viaFls: boolean }): [number, number, number, string] => [
    r.file === preferred ? 0 : 1,
    r.viaFls ? 0 : 1,
    distance(r.file, saved),
    r.file,
  ];
  return [...roots].sort((a, b) => {
    const ka = key(a);
    const kb = key(b);
    for (let i = 0; i < ka.length; i++) {
      if (ka[i] < kb[i]) return -1;
      if (ka[i] > kb[i]) return 1;
    }
    return 0;
  });
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
    for (const line of savedContent.split('\n')) {
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

  // 4. Every root that reaches the saved file, ranked.
  const reaching: { file: string; viaFls: boolean }[] = [];
  const candidates = [...new Set(fs.listTexFiles().map((p) => path.resolve(p)))].filter((p) => p !== saved);
  for (const candidate of candidates) {
    const content = fs.readFile(candidate);
    if (content === null || !hasDocumentclass(content)) continue;
    const viaFls = fs.flsInputs?.(candidate).includes(saved) ?? false;
    if (viaFls || graphReaches(candidate, saved, fs)) reaching.push({ file: candidate, viaFls });
  }
  if (reaching.length > 0) {
    const preferred = opts.preferredRoot ? path.resolve(opts.preferredRoot) : null;
    const [best] = rankRoots(reaching, saved, preferred);
    const how = best.viaFls ? '.fls of' : 'include graph from';
    const others = reaching.length > 1 ? ` (${reaching.length - 1} other root(s) also include it)` : '';
    return { root: best.file, reason: `${how} ${path.basename(best.file)}${others}` };
  }

  return { root: null, reason: 'no root found (no magic comment, setting, \\documentclass, or including root)' };
}
