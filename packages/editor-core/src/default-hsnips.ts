/// <reference path="./hsnips-assets.d.ts" />
/**
 * The default LaTeX snippet set. assets/latex.hsnips is the single source of
 * truth, copied verbatim into each host bundle: the VS Code build inlines it
 * via esbuild's `.hsnips: text` loader, the native build (web/build.mjs)
 * stages the raw file. On its own subpath (`@chalk/editor-core/default-hsnips`)
 * so the string only lands in the extension host, never the webview bundle.
 */
import bundledLatexHsnips from '../assets/latex.hsnips';

export const defaultLatexHsnips: string = bundledLatexHsnips;
