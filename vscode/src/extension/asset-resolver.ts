import * as path from 'path';
import { stripComments } from './latex/root-finder';

/**
 * Image live-preview path resolution, the extension-host twin of ChalkKit's
 * AssetResolution.swift (keep them in step). Filesystem access is injected so
 * vitest covers it without disk.
 *
 * Deliberate divergence: the native host rasterizes PDFs, Node can't without
 * heavy dependencies, so `.pdf` srcs resolve null and probing skips `pdf`.
 */

/** Raw file cap, matching AssetResolution.maxAssetBytes. */
export const MAX_ASSET_BYTES = 25 * 1024 * 1024;

export type AssetMime = 'image/png' | 'image/jpeg';

const MIME_BY_EXTENSION: Record<string, AssetMime> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
};

const PROBE_EXTENSIONS = ['png', 'jpg', 'jpeg'];

/**
 * Directories declared by `\graphicspath{{figures/}{plots/}}`, in order.
 * Best-effort (no TeX expansion): a wrong candidate only costs a failed
 * existence check.
 */
export function graphicsPaths(texSource: string): string[] {
  // Called on every resolve-asset request; most documents never declare one.
  if (!texSource.includes('\\graphicspath')) return [];
  const stripped = stripComments(texSource);

  const dirs: string[] = [];
  let search = 0;
  for (;;) {
    const cmd = stripped.indexOf('\\graphicspath', search);
    if (cmd === -1) break;
    let i = cmd + '\\graphicspath'.length;
    while (i < stripped.length && isWhitespace(stripped[i])) i++;
    if (stripped[i] !== '{') {
      search = i;
      continue;
    }
    i++;
    scan: for (;;) {
      while (i < stripped.length && isWhitespace(stripped[i])) i++;
      if (i >= stripped.length || stripped[i] === '}') {
        if (i < stripped.length) i++;
        break scan;
      }
      if (stripped[i] !== '{') break scan;
      i++;
      let dir = '';
      while (i < stripped.length && stripped[i] !== '}' && stripped[i] !== '\n') {
        dir += stripped[i];
        i++;
      }
      if (stripped[i] !== '}') break scan;
      i++;
      if (dir) dirs.push(dir);
    }
    search = i;
  }
  return dirs;
}

export interface ResolveAssetOptions {
  /** The `src` exactly as written in the document. */
  src: string;
  /** Directory of the open document; null for untitled documents (relative
   *  srcs then resolve null, absolute srcs still load). */
  documentDir: string | null;
  /** `\graphicspath` entries (tex only; pass [] for markdown). */
  graphicsPaths: string[];
  /** pdflatex-style probing for extension-less srcs (tex only). */
  allowExtensionProbing: boolean;
  fileExists: (filePath: string) => boolean;
}

/**
 * Resolve `src` to the file to load and its MIME type, or null. Dir-major:
 * the document's directory first, then each graphicspath entry; probing
 * exhausts one directory's extensions before moving on.
 */
export function resolveAssetPath(
  opts: ResolveAssetOptions,
): { filePath: string; mime: AssetMime } | null {
  const trimmed = opts.src.trim();
  if (!trimmed) return null;
  // Markdown srcs arrive percent-encoded; an invalid literal `%` throws.
  let src = trimmed;
  try {
    src = decodeURIComponent(trimmed);
  } catch {
    /* keep the original */
  }

  let candidates: string[];
  if (path.isAbsolute(src)) {
    candidates = [src];
  } else {
    const dirs: string[] = [];
    if (opts.documentDir !== null) dirs.push(opts.documentDir);
    for (const entry of opts.graphicsPaths) {
      if (path.isAbsolute(entry)) dirs.push(entry);
      else if (opts.documentDir !== null) dirs.push(path.join(opts.documentDir, entry));
    }
    candidates = dirs.map((dir) => path.join(dir, src));
  }

  const ext = path.extname(src).replace(/^\./, '');
  if (ext) {
    const mime = MIME_BY_EXTENSION[ext.toLowerCase()];
    if (!mime) return null;
    for (const filePath of candidates) {
      if (opts.fileExists(filePath)) return { filePath, mime };
    }
    return null;
  }

  if (!opts.allowExtensionProbing) return null;
  for (const stem of candidates) {
    for (const probe of PROBE_EXTENSIONS) {
      const filePath = `${stem}.${probe}`;
      if (opts.fileExists(filePath)) {
        return { filePath, mime: MIME_BY_EXTENSION[probe] };
      }
    }
  }
  return null;
}

/** `data:{mime};base64,...`, or null when the file exceeds the size cap. */
export function toDataUrl(mime: AssetMime, bytes: Uint8Array): string | null {
  if (bytes.byteLength > MAX_ASSET_BYTES) return null;
  return `data:${mime};base64,${Buffer.from(bytes).toString('base64')}`;
}

/** Injected so vitest covers the request path without a filesystem. */
export interface AssetRequestDeps {
  documentDir: string | null;
  /** tex documents get `\graphicspath` lookup and extension probing. */
  isTex: boolean;
  documentText: () => string;
  fileExists: (filePath: string) => boolean;
  readFile: (filePath: string) => Promise<Uint8Array>;
}

/**
 * Answer one webview `resolve-asset` request as a data URL; null on any
 * failure (the file can vanish between the exists check and the read).
 */
export async function answerAssetRequest(
  src: unknown,
  deps: AssetRequestDeps,
): Promise<string | null> {
  if (typeof src !== 'string') return null;
  const hit = resolveAssetPath({
    src,
    documentDir: deps.documentDir,
    graphicsPaths: deps.isTex ? graphicsPaths(deps.documentText()) : [],
    allowExtensionProbing: deps.isTex,
    fileExists: deps.fileExists,
  });
  if (!hit) return null;
  try {
    return toDataUrl(hit.mime, await deps.readFile(hit.filePath));
  } catch {
    return null;
  }
}

function isWhitespace(c: string): boolean {
  return /\s/.test(c);
}

// ---------------------------------------------------------------------------
//  Workspace listing (path + citation completion): the editor's
//  `WorkspaceAccess` seam, answered from the extension host.
// ---------------------------------------------------------------------------

const EXTENSIONS_BY_KIND: Record<string, string[]> = {
  // No `pdf`: this host can't render one (see the module comment).
  image: ['png', 'jpg', 'jpeg'],
  document: ['md', 'tex', 'qmd'],
  bib: ['bib'],
};

const MAX_LISTED_FILES = 500;
const MAX_LIST_DEPTH = 6;
/**
 * Dependency and build trees would eat the MAX_LISTED_FILES budget (and are
 * never worth scanning for .tex roots, so build-on-save's walk uses it too).
 * Dot-directories are skipped separately.
 */
export const WALK_SKIP_DIRS: ReadonlySet<string> = new Set([
  'node_modules',
  'dist',
  'out',
  '__pycache__',
]);
/** A bibliography past this is not something a popup can usefully show. */
export const MAX_READ_TEXT_BYTES = 2 * 1024 * 1024;

export interface DirEntry {
  name: string;
  isDirectory: boolean;
}

export interface ListingDeps {
  documentDir: string | null;
  readDir: (dir: string) => Promise<DirEntry[]>;
}

/** Document-relative paths of every file of the requested kinds. */
export async function listWorkspaceFiles(
  kinds: unknown,
  deps: ListingDeps,
): Promise<string[]> {
  if (!deps.documentDir || !Array.isArray(kinds)) return [];
  const wanted = new Set(
    kinds.flatMap((k) => (typeof k === 'string' ? (EXTENSIONS_BY_KIND[k] ?? []) : [])),
  );
  if (wanted.size === 0) return [];

  const out: string[] = [];
  const walk = async (dir: string, prefix: string, depth: number): Promise<void> => {
    if (depth > MAX_LIST_DEPTH || out.length >= MAX_LISTED_FILES) return;
    let entries: DirEntry[];
    try {
      entries = await deps.readDir(dir);
    } catch {
      return;
    }
    for (const entry of [...entries].sort((a, b) => a.name.localeCompare(b.name))) {
      if (out.length >= MAX_LISTED_FILES) return;
      if (entry.name.startsWith('.')) continue;
      if (entry.isDirectory) {
        if (WALK_SKIP_DIRS.has(entry.name)) continue;
        await walk(path.join(dir, entry.name), `${prefix}${entry.name}/`, depth + 1);
      } else if (wanted.has(path.extname(entry.name).slice(1).toLowerCase())) {
        out.push(prefix + entry.name);
      }
    }
  };
  await walk(deps.documentDir, '', 0);
  return out;
}

export interface ReadTextDeps {
  documentDir: string | null;
  readText: (filePath: string) => Promise<string>;
  fileSize: (filePath: string) => Promise<number>;
}

/** Read a document-relative file as text, for `.bib` parsing. `relPath`
 *  comes from the webview, so the containment check is not optional. */
export async function readWorkspaceText(
  relPath: unknown,
  deps: ReadTextDeps,
): Promise<string | null> {
  if (typeof relPath !== 'string' || !deps.documentDir) return null;
  const base = path.resolve(deps.documentDir);
  const target = path.resolve(base, relPath);
  if (!target.startsWith(base + path.sep)) return null;
  try {
    if ((await deps.fileSize(target)) > MAX_READ_TEXT_BYTES) return null;
    return await deps.readText(target);
  } catch {
    return null;
  }
}
