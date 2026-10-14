// The contract between the editor bundle and the separately built mermaid
// script (src/mermaid-entry.ts). Import-free on purpose: the entry imports it,
// and anything this file pulled in would be bundled into that script too.

/** What a diagram takes from the editor's look, read from the DOM at render time. */
export interface MermaidTheme {
  dark: boolean;
  fontFamily: string;
}

/** Renders one diagram to an SVG string; rejects when mermaid can't parse it. */
export interface MermaidRenderer {
  render(source: string, theme: MermaidTheme): Promise<string>;
}

/** The global the mermaid script registers its renderer under. */
export const MERMAID_GLOBAL = '__chalkMermaid';
