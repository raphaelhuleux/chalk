/**
 * Compute the minimal edit that turns `oldText` into `newText` — the
 * span in `oldText` to replace, and the substring of `newText` to
 * insert. Used by the host→webview update path.
 *
 * Why this exists: dispatching `from: 0, to: doc.length, insert: newText`
 * makes CM6 map every cursor position through a change that fully covers
 * it. With CM6's default assoc=-1, an "inside-the-deleted-range" cursor
 * collapses to position 0 — i.e. the cursor jumps to the top of the
 * file every time the host pushes a sync update. Replacing only the
 * differing slice means cursors in the unchanged prefix or suffix map
 * through naturally and stay where the user left them.
 *
 * Comparisons are on UTF-16 code units (`charCodeAt`) so a boundary that
 * lands inside a surrogate pair still produces a valid CM6 offset.
 */
export function diffReplace(
  oldText: string,
  newText: string,
): { from: number; to: number; insert: string } {
  const minLen = Math.min(oldText.length, newText.length);

  let prefix = 0;
  while (
    prefix < minLen &&
    oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)
  ) {
    prefix++;
  }

  let suffix = 0;
  const maxSuffix = minLen - prefix;
  while (
    suffix < maxSuffix &&
    oldText.charCodeAt(oldText.length - 1 - suffix) ===
      newText.charCodeAt(newText.length - 1 - suffix)
  ) {
    suffix++;
  }

  return {
    from: prefix,
    to: oldText.length - suffix,
    insert: newText.slice(prefix, newText.length - suffix),
  };
}
