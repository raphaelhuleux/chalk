import type { Text } from '@codemirror/state';

/**
 * Memoize a pure function of the document on `Text` identity. `Text` is
 * immutable, so caret moves hit the cache and each doc change scans once; the
 * WeakMap frees superseded docs. The value is shared: treat it as immutable.
 * Not for results that also depend on the syntax tree (md-math-plugin keeps
 * its own two-key cache).
 */
export function memoByDoc<T>(compute: (doc: Text) => T): (doc: Text) => T {
  const cache = new WeakMap<Text, T>();
  return (doc: Text): T => {
    const hit = cache.get(doc);
    // `has` only when `get` gives undefined, so any other value (even false,
    // isBeamerDoc) costs one lookup.
    if (hit !== undefined || cache.has(doc)) return hit as T;
    const value = compute(doc);
    cache.set(doc, value);
    return value;
  };
}
