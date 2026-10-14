const esbuild = require('esbuild');
const fs = require('fs');
const path = require('path');
const { woff2Only } = require('../scripts/esbuild-woff2-only.cjs');

const isWatch = process.argv.includes('--watch');
const isProd =
  process.env.NODE_ENV === 'production' || process.argv.includes('--prod');

const common = {
  bundle: true,
  sourcemap: !isProd,
  minify: isProd,
  logLevel: 'info',
};

const extensionConfig = {
  ...common,
  entryPoints: ['src/extension/index.ts'],
  outfile: 'dist/extension.js',
  platform: 'node',
  format: 'cjs',
  target: 'node16',
  external: ['vscode'],
  loader: {
    // Bundle .hsnips assets as inlined strings — read at build time,
    // embedded as string literals. Default snippets ship with the
    // extension; user files in ~/.config/hsnips override.
    '.hsnips': 'text',
  },
};

const webviewConfig = {
  ...common,
  entryPoints: ['src/webview-entry.ts'],
  outfile: 'dist/webview.js',
  platform: 'browser',
  format: 'iife',
  target: 'es2020',
  plugins: [woff2Only],
  loader: {
    '.woff': 'file',
    '.woff2': 'file',
    '.ttf': 'file',
    '.eot': 'file',
  },
};

// The mermaid renderer: its own script, injected on the first ```mermaid
// fence (scriptMermaidLoader in webview-entry.ts), so webview boot doesn't
// parse it. Always minified: it is vendor code, and unminified it is ~13 MB.
const mermaidConfig = {
  ...common,
  entryPoints: [require.resolve('@chalk/editor-core/mermaid-entry')],
  outfile: 'dist/mermaid.js',
  platform: 'browser',
  format: 'iife',
  target: 'es2020',
  minify: true,
  sourcemap: false,
};

async function run() {
  if (isWatch) {
    const [extCtx, wvCtx, mmCtx] = await Promise.all([
      esbuild.context(extensionConfig),
      esbuild.context(webviewConfig),
      esbuild.context(mermaidConfig),
    ]);
    await Promise.all([extCtx.watch(), wvCtx.watch(), mmCtx.watch()]);
    console.log('esbuild: watching...');
  } else {
    // Start from an empty dist/: hashed font files from earlier builds would
    // otherwise linger there and ship in the VSIX (`package` includes dist/**).
    fs.rmSync(path.join(__dirname, 'dist'), { recursive: true, force: true });
    await Promise.all([
      esbuild.build(extensionConfig),
      esbuild.build(webviewConfig),
      esbuild.build(mermaidConfig),
    ]);
    console.log('esbuild: done');
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
