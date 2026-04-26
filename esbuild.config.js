const esbuild = require('esbuild');

const isWatch = process.argv.includes('--watch');
const isProd = process.env.NODE_ENV === 'production';

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
  entryPoints: ['src/webview/index.ts'],
  outfile: 'dist/webview.js',
  platform: 'browser',
  format: 'iife',
  target: 'es2020',
  loader: {
    '.woff': 'file',
    '.woff2': 'file',
    '.ttf': 'file',
    '.eot': 'file',
  },
};

async function run() {
  if (isWatch) {
    const [extCtx, wvCtx] = await Promise.all([
      esbuild.context(extensionConfig),
      esbuild.context(webviewConfig),
    ]);
    await Promise.all([extCtx.watch(), wvCtx.watch()]);
    console.log('esbuild: watching...');
  } else {
    await Promise.all([
      esbuild.build(extensionConfig),
      esbuild.build(webviewConfig),
    ]);
    console.log('esbuild: done');
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
