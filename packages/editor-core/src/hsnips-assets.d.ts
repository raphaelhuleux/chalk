/** `.hsnips` imports are strings, inlined by esbuild's `text` loader
 *  (vscode/esbuild.config.js). */
declare module '*.hsnips' {
  const content: string;
  export default content;
}
