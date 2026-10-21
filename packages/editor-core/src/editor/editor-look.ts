/**
 * Reading the editor's light/dark look from the DOM, for widgets that draw
 * pictures the theme CSS can't recolour (mermaid, TikZ). Host-agnostic: the
 * computed text colour is the one signal both hosts share.
 */

/** Relative luminance of a computed `rgb(…)` colour; 0 when unparseable. */
export function luminance(color: string): number {
  const m = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/.exec(color);
  if (!m) return 0;
  const [r, g, b] = [m[1], m[2], m[3]].map((c) => {
    const s = Number(c) / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/**
 * Calls `check` whenever the look may have changed: the native host flips
 * `data-theme` / `data-palette` on <html>, VS Code swaps <body> classes, and
 * the OS appearance can change under either. Config pushes reconfigure the
 * view instead, so callers also check on `tr.reconfigured`. Returns the
 * disposer.
 */
export function observeLook(check: () => void): () => void {
  const observer = new MutationObserver(check);
  const attributeFilter = ['class', 'style', 'data-theme', 'data-palette'];
  observer.observe(document.documentElement, { attributes: true, attributeFilter });
  observer.observe(document.body, { attributes: true, attributeFilter });
  const media = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
  media?.addEventListener('change', check);
  return () => {
    observer.disconnect();
    media?.removeEventListener('change', check);
  };
}
