import { Facet } from '@codemirror/state';

/**
 * Read access to the files around the document, for path and `\cite{`
 * completion. Host-owned: walking a directory needs sandbox scope editor-core
 * lacks (`AssetResolver` only resolves one known image path). A per-editor
 * facet, empty by default so an unwired host offers nothing.
 *
 * Host limitation: a host whose access is scoped to the one open file (no
 * granted folder around it) returns an empty `list`.
 */
export type WorkspaceFileKind = 'image' | 'document' | 'bib';

export interface WorkspaceAccess {
  /** Document-relative paths of the listed kinds. Host-walked, depth- and
   *  count-capped; order is the host's. */
  list(kinds: readonly WorkspaceFileKind[]): Promise<string[]>;
  /** File text, for `.bib` parsing. Null when unreadable or oversized. */
  readText(path: string): Promise<string | null>;
}

const noopAccess: WorkspaceAccess = {
  list: () => Promise.resolve([]),
  readText: () => Promise.resolve(null),
};

export const workspaceAccessFacet = Facet.define<WorkspaceAccess, WorkspaceAccess>({
  combine: (values) => (values.length ? values[0] : noopAccess),
});

// ── Listing cache ───────────────────────────────────────────────────
//
// Without a cache, typing `figures/` walks the workspace once per character.
// Keyed by the access object, which mountEditor reuses across `init`s, so
// only the short TTL expires it (files can appear while the editor is open).

const LISTING_TTL_MS = 5_000;

interface CacheEntry {
  at: number;
  paths: Promise<string[]>;
}

const listingCache = new WeakMap<WorkspaceAccess, Map<string, CacheEntry>>();

export function listFiles(
  access: WorkspaceAccess,
  kinds: readonly WorkspaceFileKind[],
): Promise<string[]> {
  let perKind = listingCache.get(access);
  if (!perKind) {
    perKind = new Map();
    listingCache.set(access, perKind);
  }
  const key = [...kinds].sort().join(',');
  const hit = perKind.get(key);
  const now = Date.now();
  if (hit && now - hit.at < LISTING_TTL_MS) return hit.paths;

  const paths = access.list(kinds).catch(() => []);
  perKind.set(key, { at: now, paths });
  return paths;
}

// ── BibTeX keys ─────────────────────────────────────────────────────

/** Entry types that carry no citation key. */
const NON_ENTRY = new Set(['string', 'comment', 'preamble']);

/** Citation keys from a `.bib` file. Parsed here, not in the host, so both
 *  hosts agree and it is testable without a filesystem. */
export function bibliographyKeys(text: string): string[] {
  const keys: string[] = [];
  const re = /@(\w+)\s*\{\s*([^\s,{}]+)\s*,/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (NON_ENTRY.has(m[1].toLowerCase())) continue;
    keys.push(m[2]);
  }
  return keys;
}

/** Every key across every `.bib` the host lists. */
export async function workspaceCitations(
  access: WorkspaceAccess,
): Promise<Array<{ key: string; file: string }>> {
  const files = await listFiles(access, ['bib']);
  // Concurrent: each read is a host round trip.
  const texts = await Promise.all(files.map((file) => access.readText(file).catch(() => null)));
  return files.flatMap((file, i) => {
    const text = texts[i];
    return text ? bibliographyKeys(text).map((key) => ({ key, file })) : [];
  });
}
