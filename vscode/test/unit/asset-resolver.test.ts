import { describe, it, expect } from 'vitest';
import {
  answerAssetRequest,
  graphicsPaths,
  resolveAssetPath,
  toDataUrl,
  MAX_ASSET_BYTES,
  listWorkspaceFiles,
  readWorkspaceText,
  MAX_READ_TEXT_BYTES,
  type DirEntry,
} from '../../src/extension/asset-resolver';

/** fileExists backed by a plain list of absolute paths. */
function fs(...paths: string[]): (p: string) => boolean {
  const set = new Set(paths);
  return (p) => set.has(p);
}

describe('graphicsPaths', () => {
  it('parses a single command with multiple dirs in order', () => {
    expect(graphicsPaths('\\graphicspath{{figures/}{plots/}}')).toEqual([
      'figures/',
      'plots/',
    ]);
  });

  it('accumulates across multiple commands in declaration order', () => {
    const source = '\\graphicspath{{a/}}\ntext\n\\graphicspath{{b/}}';
    expect(graphicsPaths(source)).toEqual(['a/', 'b/']);
  });

  it('ignores commented-out commands but honors escaped percent', () => {
    const source = '% \\graphicspath{{dead/}}\n\\graphicspath{{live/}} % 100\\% sure';
    expect(graphicsPaths(source)).toEqual(['live/']);
  });

  it('tolerates whitespace between the command and its groups', () => {
    expect(graphicsPaths('\\graphicspath {  {figures/}  {plots/} }')).toEqual([
      'figures/',
      'plots/',
    ]);
  });

  it('returns empty for sources without the command', () => {
    expect(graphicsPaths('\\includegraphics{plot}')).toEqual([]);
  });
});

describe('resolveAssetPath', () => {
  const base = {
    documentDir: '/docs' as string | null,
    graphicsPaths: [] as string[],
    allowExtensionProbing: false,
  };

  it('resolves a relative png against the document directory', () => {
    const hit = resolveAssetPath({
      ...base,
      src: 'figures/plot.png',
      fileExists: fs('/docs/figures/plot.png'),
    });
    expect(hit).toEqual({ filePath: '/docs/figures/plot.png', mime: 'image/png' });
  });

  it('maps jpg and jpeg extensions to image/jpeg', () => {
    const hit = resolveAssetPath({
      ...base,
      src: 'photo.JPG',
      fileExists: fs('/docs/photo.JPG'),
    });
    expect(hit).toEqual({ filePath: '/docs/photo.JPG', mime: 'image/jpeg' });
  });

  it('percent-decodes markdown srcs', () => {
    const hit = resolveAssetPath({
      ...base,
      src: 'my%20plot.png',
      fileExists: fs('/docs/my plot.png'),
    });
    expect(hit?.filePath).toBe('/docs/my plot.png');
  });

  it('keeps the original src when percent-decoding fails', () => {
    const hit = resolveAssetPath({
      ...base,
      src: '100%plot.png',
      fileExists: fs('/docs/100%plot.png'),
    });
    expect(hit?.filePath).toBe('/docs/100%plot.png');
  });

  it('loads absolute paths without touching base dirs', () => {
    const hit = resolveAssetPath({
      ...base,
      src: '/elsewhere/fig.png',
      fileExists: fs('/elsewhere/fig.png'),
    });
    expect(hit?.filePath).toBe('/elsewhere/fig.png');
  });

  it('returns null for unsupported extensions', () => {
    expect(
      resolveAssetPath({
        ...base,
        src: 'anim.gif',
        fileExists: fs('/docs/anim.gif'),
      }),
    ).toBeNull();
  });

  it('returns null for explicit .pdf srcs (no rasterizer in the extension host)', () => {
    expect(
      resolveAssetPath({
        ...base,
        src: 'figure.pdf',
        fileExists: fs('/docs/figure.pdf'),
      }),
    ).toBeNull();
  });

  it('falls back to graphicspath dirs after the document dir', () => {
    const hit = resolveAssetPath({
      ...base,
      graphicsPaths: ['figures/'],
      src: 'plot.png',
      fileExists: fs('/docs/figures/plot.png'),
    });
    expect(hit?.filePath).toBe('/docs/figures/plot.png');
  });

  it('honors absolute graphicspath entries', () => {
    const hit = resolveAssetPath({
      ...base,
      graphicsPaths: ['/shared/figs/'],
      src: 'plot.png',
      fileExists: fs('/shared/figs/plot.png'),
    });
    expect(hit?.filePath).toBe('/shared/figs/plot.png');
  });

  it('probes extensions for extension-less tex srcs, png first', () => {
    const hit = resolveAssetPath({
      ...base,
      allowExtensionProbing: true,
      src: 'plot',
      fileExists: fs('/docs/plot.png', '/docs/plot.jpg'),
    });
    expect(hit).toEqual({ filePath: '/docs/plot.png', mime: 'image/png' });
  });

  it('skips pdf while probing so a sibling png still renders', () => {
    const hit = resolveAssetPath({
      ...base,
      allowExtensionProbing: true,
      src: 'plot',
      fileExists: fs('/docs/plot.pdf', '/docs/plot.png'),
    });
    expect(hit?.filePath).toBe('/docs/plot.png');
  });

  it('exhausts one directory before moving to the next (dir-major)', () => {
    const hit = resolveAssetPath({
      ...base,
      allowExtensionProbing: true,
      graphicsPaths: ['figures/'],
      src: 'plot',
      fileExists: fs('/docs/plot.jpeg', '/docs/figures/plot.png'),
    });
    expect(hit?.filePath).toBe('/docs/plot.jpeg');
  });

  it('does not probe when probing is disabled (markdown)', () => {
    expect(
      resolveAssetPath({
        ...base,
        src: 'plot',
        fileExists: fs('/docs/plot.png'),
      }),
    ).toBeNull();
  });

  it('resolves nothing relative for untitled documents but still loads absolute srcs', () => {
    const untitled = { ...base, documentDir: null };
    expect(
      resolveAssetPath({
        ...untitled,
        src: 'plot.png',
        fileExists: fs('/docs/plot.png'),
      }),
    ).toBeNull();
    expect(
      resolveAssetPath({
        ...untitled,
        src: '/docs/plot.png',
        fileExists: fs('/docs/plot.png'),
      }),
    ).not.toBeNull();
  });

  it('returns null for empty or whitespace srcs', () => {
    expect(
      resolveAssetPath({ ...base, src: '   ', fileExists: fs() }),
    ).toBeNull();
  });
});

describe('answerAssetRequest', () => {
  const png = new Uint8Array([137, 80, 78, 71]);
  const deps = {
    documentDir: '/docs' as string | null,
    isTex: false,
    documentText: () => '',
    fileExists: fs('/docs/plot.png'),
    readFile: async (p: string) => {
      if (p !== '/docs/plot.png') throw new Error(`unexpected read: ${p}`);
      return png;
    },
  };

  it('answers a resolvable src with a data URL', async () => {
    await expect(answerAssetRequest('plot.png', deps)).resolves.toBe(
      `data:image/png;base64,${Buffer.from(png).toString('base64')}`,
    );
  });

  it('answers null for a non-string src', async () => {
    await expect(answerAssetRequest(42, deps)).resolves.toBeNull();
  });

  it('answers null for an unresolvable src', async () => {
    await expect(answerAssetRequest('missing.png', deps)).resolves.toBeNull();
  });

  it('answers null when the read fails (file vanished after the exists check)', async () => {
    await expect(
      answerAssetRequest('plot.png', {
        ...deps,
        readFile: async () => {
          throw new Error('ENOENT');
        },
      }),
    ).resolves.toBeNull();
  });

  it('answers null for oversized files', async () => {
    await expect(
      answerAssetRequest('plot.png', {
        ...deps,
        readFile: async () => new Uint8Array(MAX_ASSET_BYTES + 1),
      }),
    ).resolves.toBeNull();
  });

  it('reads graphicspath from the tex source and probes extensions', async () => {
    const url = await answerAssetRequest('plot', {
      documentDir: '/docs',
      isTex: true,
      documentText: () => '\\graphicspath{{figures/}}',
      fileExists: fs('/docs/figures/plot.png'),
      readFile: async (p: string) => {
        if (p !== '/docs/figures/plot.png') throw new Error(`unexpected read: ${p}`);
        return png;
      },
    });
    expect(url).toContain('data:image/png;base64,');
  });

  it('does not probe or read graphicspath for markdown', async () => {
    await expect(
      answerAssetRequest('plot', {
        ...deps,
        documentText: () => '\\graphicspath{{figures/}}',
        fileExists: fs('/docs/plot.png', '/docs/figures/plot.png'),
      }),
    ).resolves.toBeNull();
  });
});

describe('toDataUrl', () => {
  it('encodes bytes as a base64 data URL', () => {
    const bytes = new Uint8Array([137, 80, 78, 71]);
    expect(toDataUrl('image/png', bytes)).toBe(
      `data:image/png;base64,${Buffer.from(bytes).toString('base64')}`,
    );
  });

  it('refuses files over the size cap', () => {
    const oversized = new Uint8Array(MAX_ASSET_BYTES + 1);
    expect(toDataUrl('image/png', oversized)).toBeNull();
  });
});

// ── Workspace listing (path + citation completion) ───────────────────

describe('listWorkspaceFiles', () => {
  const TREE: Record<string, DirEntry[]> = {
    '/doc': [
      { name: 'notes.md', isDirectory: false },
      { name: 'refs.bib', isDirectory: false },
      { name: 'figures', isDirectory: true },
      { name: '.hidden', isDirectory: true },
      { name: 'readme.txt', isDirectory: false },
    ],
    '/doc/figures': [
      { name: 'plot.PNG', isDirectory: false },
      { name: 'scan.jpg', isDirectory: false },
    ],
    '/doc/.hidden': [{ name: 'secret.png', isDirectory: false }],
  };
  const readDir = async (dir: string): Promise<DirEntry[]> => {
    const entries = TREE[dir];
    if (!entries) throw new Error('ENOENT');
    return entries;
  };

  it('lists images relative to the document directory', async () => {
    expect(await listWorkspaceFiles(['image'], { documentDir: '/doc', readDir })).toEqual([
      'figures/plot.PNG',
      'figures/scan.jpg',
    ]);
  });

  it('separates documents from bibliographies', async () => {
    expect(await listWorkspaceFiles(['document'], { documentDir: '/doc', readDir })).toEqual([
      'notes.md',
    ]);
    expect(await listWorkspaceFiles(['bib'], { documentDir: '/doc', readDir })).toEqual([
      'refs.bib',
    ]);
  });

  it('skips hidden directories and unknown types', async () => {
    const all = await listWorkspaceFiles(['image', 'document', 'bib'], {
      documentDir: '/doc',
      readDir,
    });
    expect(all).not.toContain('.hidden/secret.png');
    expect(all).not.toContain('readme.txt');
  });

  it('does not descend into dependency or build directories', async () => {
    const tree: Record<string, DirEntry[]> = {
      '/doc': [
        { name: 'node_modules', isDirectory: true },
        { name: 'dist', isDirectory: true },
        { name: 'out', isDirectory: true },
        { name: '__pycache__', isDirectory: true },
        { name: 'figures', isDirectory: true },
      ],
      '/doc/figures': [{ name: 'plot.png', isDirectory: false }],
    };
    const visited: string[] = [];
    const tracingReadDir = async (dir: string): Promise<DirEntry[]> => {
      visited.push(dir);
      return tree[dir] ?? [{ name: 'vendored.png', isDirectory: false }];
    };
    expect(
      await listWorkspaceFiles(['image'], { documentDir: '/doc', readDir: tracingReadDir }),
    ).toEqual(['figures/plot.png']);
    expect(visited).toEqual(['/doc', '/doc/figures']);
  });

  it('offers nothing for an untitled document', async () => {
    expect(await listWorkspaceFiles(['image'], { documentDir: null, readDir })).toEqual([]);
  });

  it('offers nothing for an unreadable directory', async () => {
    expect(await listWorkspaceFiles(['image'], { documentDir: '/nope', readDir })).toEqual([]);
  });

  it('ignores kinds it does not know', async () => {
    expect(await listWorkspaceFiles(['nonsense'], { documentDir: '/doc', readDir })).toEqual([]);
  });
});

describe('readWorkspaceText', () => {
  const deps = {
    documentDir: '/doc',
    readText: async (p: string) => `contents of ${p}`,
    fileSize: async () => 10,
  };

  it('reads a file inside the document directory', async () => {
    expect(await readWorkspaceText('refs.bib', deps)).toBe('contents of /doc/refs.bib');
  });

  it('refuses a path that escapes the document directory', async () => {
    expect(await readWorkspaceText('../../etc/passwd', deps)).toBeNull();
  });

  it('refuses an absolute path outside the document directory', async () => {
    expect(await readWorkspaceText('/etc/passwd', deps)).toBeNull();
  });

  it('refuses a file past the size cap', async () => {
    expect(
      await readWorkspaceText('refs.bib', {
        ...deps,
        fileSize: async () => MAX_READ_TEXT_BYTES + 1,
      }),
    ).toBeNull();
  });

  it('returns null when the read fails', async () => {
    expect(
      await readWorkspaceText('refs.bib', {
        ...deps,
        readText: async () => {
          throw new Error('EACCES');
        },
      }),
    ).toBeNull();
  });
});
