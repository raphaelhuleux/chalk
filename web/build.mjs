// Builds the WKWebView editor bundle from @chalk/editor-core (packages/editor-core).
//
// editor-core is a workspace dependency whose package.json points at its
// TypeScript source, so esbuild bundles it (and its CodeMirror/KaTeX deps) as
// installed by `pnpm install` at the repo root. Fonts (KaTeX + IBM Plex Mono)
// inline as data: URLs so nothing loads from a file path inside the
// sandboxed webview.
import * as esbuild from 'esbuild';
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { woff2Only } from '../scripts/esbuild-woff2-only.cjs';

const here = dirname(fileURLToPath(import.meta.url));
const dist = resolve(here, 'dist');
const editorCore = resolve(here, '../packages/editor-core');
const minify = process.env.MINIFY === '1';

/** Every file under `dir`, as paths relative to it. */
function listFiles(dir, prefix = '') {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries.flatMap((e) =>
    e.isDirectory()
      ? listFiles(join(dir, e.name), `${prefix}${e.name}/`)
      : [`${prefix}${e.name}`],
  );
}

/**
 * Make `dir` hold exactly `files` (relative path → bytes): write only the
 * files whose bytes differ, delete the ones no longer produced. An unchanged
 * build then touches nothing, so mtimes stay put and Xcode's resource copy of
 * Resources/editor has nothing to redo. Returns the number of changes.
 */
function syncDir(dir, files) {
  mkdirSync(dir, { recursive: true });
  let changes = 0;
  for (const [name, bytes] of files) {
    const target = join(dir, name);
    let current = null;
    try {
      current = readFileSync(target);
    } catch {
      // missing (or not a file): write it
    }
    if (current && current.equals(bytes)) continue;
    rmSync(target, { recursive: true, force: true });
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, bytes);
    changes++;
  }
  for (const name of listFiles(dir)) {
    if (files.has(name)) continue;
    rmSync(join(dir, name), { force: true });
    changes++;
  }
  removeEmptyDirs(dir);
  return changes;
}

/** Delete the directories under `dir` that pruning left empty. */
function removeEmptyDirs(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const sub = join(dir, e.name);
    removeEmptyDirs(sub);
    if (readdirSync(sub).length === 0) rmSync(sub, { recursive: true });
  }
}

// Built in memory (`write: false`) and written through syncDir below, instead
// of wiping dist/ and Resources/editor on every run. The two builds are
// independent, so they run concurrently.
const [result, mermaidResult] = await Promise.all([
  esbuild.build({
    // Pinned so the bundle's path comments (relative to this dir) do not depend
    // on where the build is invoked from.
    absWorkingDir: here,
    entryPoints: [resolve(here, 'src/native-host.ts')],
    bundle: true,
    format: 'iife',
    outdir: dist,
    entryNames: 'bundle', // → dist/bundle.js + dist/bundle.css
    plugins: [woff2Only],
    loader: {
      '.woff2': 'dataurl',
      '.woff': 'dataurl',
      '.ttf': 'dataurl',
      '.eot': 'dataurl',
    },
    minify,
    sourcemap: false,
    write: false,
    logLevel: 'info',
  }),
  // The mermaid renderer: its own script, injected on the first ```mermaid
  // fence (scriptMermaidLoader in native-host.ts), so the editor's boot doesn't
  // parse it. Always minified: it is vendor code, and unminified it is ~13 MB.
  esbuild.build({
    absWorkingDir: here,
    entryPoints: { mermaid: resolve(editorCore, 'src/mermaid-entry.ts') },
    bundle: true,
    format: 'iife',
    outdir: dist,
    minify: true,
    sourcemap: false,
    write: false,
    logLevel: 'info',
  }),
]);

const outputs = new Map(
  [...result.outputFiles, ...mermaidResult.outputFiles].map((f) => [
    relative(dist, f.path).split(sep).join('/'),
    Buffer.from(f.contents),
  ]),
);
// Static HTML shell.
outputs.set('editor.html', readFileSync(resolve(here, 'src/editor.html')));
// The default snippet set: copied from editor-core (single source of truth)
// so the Swift host can bundle it and push it via the `hsnips` message after
// `init`.
outputs.set('latex.hsnips', readFileSync(resolve(editorCore, 'assets/latex.hsnips')));

// Stage the bundle into the app's Resources so Xcode ships it. Both this dir
// and dist/ are gitignored build artifacts; an Xcode pre-build phase re-runs
// this script so the editor in the app bundle is always current.
const appEditorRes = resolve(here, '../mac/Chalk/Resources/editor');
const distChanges = syncDir(dist, outputs);
const appChanges = syncDir(appEditorRes, outputs);

const changed = (n) => (n === 0 ? 'unchanged' : `${n} file(s) changed`);
console.log(`built web bundle → ${dist} (${changed(distChanges)})`);
console.log(
  `staged into app   → ${appEditorRes}${minify ? ' (minified)' : ''} (${changed(appChanges)})`,
);
