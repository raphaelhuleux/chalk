/**
 * Module declaration for `.hsnips` text imports. esbuild's `text` loader
 * (configured in esbuild.config.js) reads the file at build time and
 * embeds its contents as a string literal in the bundle. TypeScript needs
 * this declaration to recognize the otherwise-untyped import.
 */
declare module '*.hsnips' {
  const content: string;
  export default content;
}
