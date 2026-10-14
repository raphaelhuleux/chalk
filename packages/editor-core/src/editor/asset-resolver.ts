import { Facet } from '@codemirror/state';

/**
 * Host-supplied: resolves an image `src` (relative/absolute path or URL) to a
 * URL an `<img>` can load, or null. Both hosts answer a `resolve-asset` request
 * (host-request.ts). A per-editor Facet so each tab resolves against its own
 * directory.
 */
export type AssetResolver = (src: string) => Promise<string | null>;

const noopResolver: AssetResolver = () => Promise.resolve(null);

export const assetResolverFacet = Facet.define<AssetResolver, AssetResolver>({
  combine: (values) => (values.length ? values[0] : noopResolver),
});
