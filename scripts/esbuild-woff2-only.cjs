// esbuild plugin shared by web/build.mjs and vscode/esbuild.config.js.
//
// KaTeX's and fontsource's @font-face rules list woff2 first, then woff (and,
// for KaTeX, ttf) fallbacks. Every engine either host targets (WebKit on
// iOS 17 / macOS 14, VS Code's Electron) reads woff2, so the fallbacks never
// load, yet esbuild's dataurl/file loaders would inline or emit all of them
// (about 1.2 MB of the native bundle.css, about 876 KB of the VSIX). Drop them
// from the dependency CSS before esbuild resolves the url()s, so they are
// never read. A `src` without a woff2 entry is left alone.
const fs = require('fs');
const path = require('path');

const woff2Only = {
  name: 'woff2-only',
  setup(build) {
    build.onLoad({ filter: /\.css$/ }, (args) => {
      if (!args.path.includes(`${path.sep}node_modules${path.sep}`)) return undefined;
      const css = fs.readFileSync(args.path, 'utf8');
      const stripped = css.replace(/\bsrc\s*:[^;}]*/g, (decl) =>
        /format\(\s*["']?woff2["']?\s*\)/.test(decl)
          ? decl.replace(/\s*,\s*url\([^)]*\)\s*format\(\s*["']?(?:woff|truetype|opentype|embedded-opentype)["']?\s*\)/g, '')
          : decl,
      );
      if (stripped === css) return undefined;
      return { contents: stripped, loader: 'css', resolveDir: path.dirname(args.path) };
    });
  },
};

module.exports = { woff2Only };
