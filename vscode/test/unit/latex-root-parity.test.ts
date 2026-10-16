import { readFileSync } from 'fs';
import path from 'path';
import { describe, expect, it } from 'vitest';
import { findLatexRoot } from '../../src/extension/latex/root-finder';

/**
 * The cases in test/fixtures/latex-roots.json also run against the Mac
 * app's Swift port (mac/ChalkKit LatexRootParityTests). A rule change must
 * land in both finders, and its case here.
 */
interface Case {
  name: string;
  files: Record<string, string>;
  fls?: Record<string, string[]>;
  saved: string;
  options: { configuredRoot?: string; workspaceDir?: string; preferredRoot?: string };
  root: string | null;
  reasonContains?: string;
}

const { cases } = JSON.parse(
  readFileSync(path.resolve(__dirname, '../fixtures/latex-roots.json'), 'utf8'),
) as { cases: Case[] };

describe('findLatexRoot shared cases', () => {
  it.each(cases.map((c) => [c.name, c] as const))('%s', (_name, c) => {
    const r = findLatexRoot(
      c.saved,
      {
        readFile: (p) => c.files[p] ?? null,
        exists: (p) => p in c.files,
        listTexFiles: () => Object.keys(c.files).filter((p) => p.endsWith('.tex')),
        flsInputs: (root) => c.fls?.[root] ?? [],
      },
      c.options,
    );
    expect(r.root).toBe(c.root);
    if (c.reasonContains) expect(r.reason).toContain(c.reasonContains);
  });
});
