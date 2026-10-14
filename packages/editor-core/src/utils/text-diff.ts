/**
 * The minimal edit turning `oldText` into `newText`, for host `update`s. Don't
 * replace with a full-text replace: CM6 maps a cursor inside a fully covered
 * range to 0, so every sync would lose the cursor and viewport. UTF-16 code
 * units, so a boundary inside a surrogate pair is still a valid CM6 offset.
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
