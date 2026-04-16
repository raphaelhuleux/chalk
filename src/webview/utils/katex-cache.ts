import katex from 'katex';
import 'katex/dist/katex.min.css';

/**
 * LRU cache for KaTeX render results.
 *
 * Keyed by display-mode prefix + LaTeX source. Uses Map insertion
 * order for O(1) LRU eviction: delete-then-set on every access
 * keeps the most-recently-used entry at the end; the first key
 * returned by the iterator is always the oldest.
 */
export class KaTeXCache {
  private cache: Map<string, string>;
  private maxSize: number;

  constructor(maxSize: number = 500) {
    this.cache = new Map();
    this.maxSize = maxSize;
  }

  /**
   * Render LaTeX to an HTML string, returning the cached result
   * when available. Returns null on KaTeX ParseError so the caller
   * can show the raw source with error styling.
   */
  render(latex: string, displayMode: boolean): string | null {
    const key = `${displayMode ? 'D' : 'I'}:${latex}`;

    if (this.cache.has(key)) {
      const value = this.cache.get(key)!;
      // Move to end (most recently used)
      this.cache.delete(key);
      this.cache.set(key, value);
      return value;
    }

    try {
      const html = katex.renderToString(latex, {
        displayMode,
        throwOnError: true,
      });

      // Evict oldest entry if at capacity
      if (this.cache.size >= this.maxSize) {
        const oldest = this.cache.keys().next().value!;
        this.cache.delete(oldest);
      }

      this.cache.set(key, html);
      return html;
    } catch (err) {
      if (err instanceof katex.ParseError) {
        return null;
      }
      throw err;
    }
  }

  invalidate(latex: string): void {
    this.cache.delete(`D:${latex}`);
    this.cache.delete(`I:${latex}`);
  }

  clear(): void {
    this.cache.clear();
  }

  get size(): number {
    return this.cache.size;
  }
}
