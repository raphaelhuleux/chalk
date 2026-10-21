import { Facet } from '@codemirror/state';

/**
 * Host-supplied: typesets a standalone LaTeX document (tikz-source.ts) and
 * answers with an image URL and its CSS size, or the TeX error. null means no
 * renderer here (no TeX installed, or a sandboxed build): the source stays
 * plain. The native host answers a `render-tikz` request (host-request.ts).
 */
export type TikzResult = { url: string; width: number; height: number } | { error: string };

export type TikzRenderer = (document: string) => Promise<TikzResult | null>;

/** Without one, TikZ pictures render as their source only. */
export const tikzRendererFacet = Facet.define<TikzRenderer, TikzRenderer | null>({
  combine: (values) => values[0] ?? null,
});
