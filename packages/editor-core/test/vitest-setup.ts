// Suite-wide jsdom polyfills, loaded via vitest.config.ts `setupFiles`
// (runs at the top of every test file, before its imports).
//
// jsdom implements no layout, so `Range.prototype.getClientRects` /
// `getBoundingClientRect` don't exist. CodeMirror's measure cycle calls them
// from a requestAnimationFrame that can fire AFTER the test that created the
// view finished — an uncaught exception outside any test, which fails the
// whole run (vitest exit 1) even when every assertion passed. Tests should
// still destroy their views (repo convention), but this makes a forgotten
// destroy a non-event instead of a red suite.
if (typeof Range.prototype.getClientRects !== 'function') {
  Range.prototype.getClientRects = () => [] as unknown as DOMRectList;
}
if (typeof Range.prototype.getBoundingClientRect !== 'function') {
  Range.prototype.getBoundingClientRect = () =>
    ({ x: 0, y: 0, width: 0, height: 0, top: 0, right: 0, bottom: 0, left: 0, toJSON: () => ({}) }) as DOMRect;
}
