import { describe, it, expect } from 'vitest';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import * as os from 'node:os';
import { loadMergedTokenColors } from '../../src/extension/theme-reader';

/**
 * The include-chain resolver must terminate even when themes form a
 * cycle (A includes B, B includes A) — the depth cap alone re-reads
 * each file at every level, the visited-set short-circuits revisits.
 */
describe('loadMergedTokenColors — include cycle detection', () => {
  it('terminates on a 2-file cycle and returns merged tokens once', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'chalk-theme-'));
    const aPath = path.join(dir, 'a.json');
    const bPath = path.join(dir, 'b.json');
    await fs.writeFile(
      aPath,
      JSON.stringify({
        include: './b.json',
        tokenColors: [{ scope: 'keyword', settings: { foreground: '#aaaaaa' } }],
      }),
    );
    await fs.writeFile(
      bPath,
      JSON.stringify({
        include: './a.json',
        tokenColors: [{ scope: 'comment', settings: { foreground: '#bbbbbb' } }],
      }),
    );

    const tokens = await loadMergedTokenColors(aPath);
    // Cycle short-circuits on revisit, so each file's tokenColors appears
    // exactly once. Order: includes resolved first, then this file's
    // tokenColors appended.
    const scopes = tokens.map((t) => t.scope).filter(Boolean);
    expect(scopes).toContain('keyword');
    expect(scopes).toContain('comment');
    // No duplicates — without cycle detection the loop would keep
    // appending until depth cap.
    expect(scopes.filter((s) => s === 'keyword').length).toBe(1);
    expect(scopes.filter((s) => s === 'comment').length).toBe(1);

    await fs.rm(dir, { recursive: true });
  });

  it('handles a self-referential include without infinite recursion', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'chalk-theme-'));
    const themePath = path.join(dir, 'self.json');
    await fs.writeFile(
      themePath,
      JSON.stringify({
        include: './self.json',
        tokenColors: [{ scope: 'string', settings: { foreground: '#cccccc' } }],
      }),
    );

    const tokens = await loadMergedTokenColors(themePath);
    // Visited set prevents the same file from contributing tokens twice.
    expect(tokens.filter((t) => t.scope === 'string').length).toBe(1);

    await fs.rm(dir, { recursive: true });
  });
});
