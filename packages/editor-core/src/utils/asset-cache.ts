import type { AssetResolver } from '../editor/asset-resolver';

/**
 * Per-editor LRU over a host asset resolver: CM6 rebuilds image widgets on
 * every scroll, and each resolve is a round trip carrying base64. In-flight
 * promises are shared. Null results are evicted at once so a file saved
 * moments later appears on the next rebuild.
 */
export function memoizedAssetResolver(resolver: AssetResolver, maxSize = 32): AssetResolver {
  const cache = new Map<string, Promise<string | null>>();

  return (src) => {
    const hit = cache.get(src);
    if (hit) {
      cache.delete(src);
      cache.set(src, hit);
      return hit;
    }

    const entry: Promise<string | null> = resolver(src)
      .catch(() => null)
      .then((url) => {
        // Only if still this entry: a later request may have cached a newer one.
        if (url === null && cache.get(src) === entry) cache.delete(src);
        return url;
      });

    cache.set(src, entry);
    if (cache.size > maxSize) {
      const oldest = cache.keys().next().value;
      if (oldest !== undefined) cache.delete(oldest);
    }
    return entry;
  };
}
