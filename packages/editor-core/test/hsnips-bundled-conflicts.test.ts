import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { EditorState, EditorSelection } from '@codemirror/state';
import { parseHSnips, type HSnippet } from '../src/editor/hsnips-parser';
import { _testing } from '../src/editor/hsnips-plugin';

/**
 * Every bundled snippet must be reachable by typing its own trigger.
 *
 * `findMatch` returns the FIRST match in priority order, and built-ins are
 * priority 0, so file order breaks ties. With the `i` (inword) flag matching
 * on `endsWith`, any trigger that is a suffix of a later trigger makes that
 * later one unreachable — `bar` ate `hbar`, `set` ate `subset`. Raise the
 * specific snippet's `priority` (or move it earlier) when this fails.
 *
 * A trigger can also go dead while staying perfectly reachable, by no longer
 * saying what it means: six had been overwritten by their own neighbours'
 * expansions, because the file was edited somewhere with these snippets live
 * (`ii` → `\mathrm{i}` turned the `iint` trigger into `\mathrm{i}nt`). No
 * mechanical check can spot that, so those are pinned by name below.
 */
const BUNDLED = readFileSync(join(__dirname, '../assets/latex.hsnips'), 'utf8');
const snippets = parseHSnips(BUNDLED);

const keyOf = (s: HSnippet) => s.regexpSource ?? s.trigger;

/**
 * A string the pattern should match, covering the constructs this file uses.
 * Returns null when the pattern is too complex to sample, which is reported
 * rather than silently skipped.
 */
function sampleForRegex(src: string): string | null {
  let out = src
    .replace(/\\b/g, '')
    .replace(/\(\[ \]\*\)/g, '')
    .replace(/\(\[a-zA-Z\]\)/g, 'a')
    .replace(/\(\[a-gi-zA-Z\]\)/g, 'a')
    .replace(/\(\[a-ce-zA-Z\]\)/g, 'a')
    .replace(/\(\[A-Za-z\]\)/g, 'a')
    .replace(/\(\[\^no\]\)/g, 'q')
    .replace(/\(\\d\\d\)/g, '12')
    .replace(/\(\\d\)/g, '1')
    .replace(/\\\\/g, '\\')
    .replace(/\\([{}$.,^_[\]()|*+?:])/g, '$1');
  if (/[[\]()*+?|\\]/.test(out)) return null;
  return out;
}

function winnerFor(s: HSnippet): HSnippet | null | undefined {
  const text = s.trigger || sampleForRegex(s.regexpSource!);
  if (text === null) return undefined; // unsampled
  const state = EditorState.create({
    doc: text,
    selection: EditorSelection.cursor(text.length),
  });
  // Evaluate in the context the snippet itself asks for, and let Tab-only
  // snippets compete, so neither is excluded for the wrong reason.
  const inMath = s.contextFilter !== '!math(context)';
  return _testing.findMatch(state, snippets, () => inMath, true)?.snippet ?? null;
}

describe('bundled snippets are all reachable', () => {
  it('has no duplicate triggers', () => {
    const seen = new Map<string, number>();
    for (const s of snippets) seen.set(keyOf(s), (seen.get(keyOf(s)) ?? 0) + 1);
    expect([...seen].filter(([, n]) => n > 1)).toEqual([]);
  });

  it('every snippet wins on its own trigger', () => {
    const broken: string[] = [];
    for (const s of snippets) {
      const win = winnerFor(s);
      if (win === undefined) continue; // regex we cannot sample
      if (win === null) {
        broken.push(`${keyOf(s)}: nothing matches its own trigger`);
      } else if (win !== s) {
        broken.push(`${keyOf(s)}: shadowed by ${keyOf(win)}`);
      }
    }
    expect(broken).toEqual([]);
  });

  it('keeps the triggers that were overwritten by their neighbours', () => {
    // Each of these was a literal trigger that its neighbour's snippet
    // expanded in place: `subseteq` → `\subset eq`, `iint` → `\mathrm{i}nt`,
    // `iiint` → `\mathrm{i}int`. Reachable as nonsense, useless as shortcuts.
    const triggers = new Set(snippets.map((s) => s.trigger));
    for (const t of ['subseteq', 'iint', 'iiint', 'exists', 'xii']) {
      expect(triggers, `missing trigger ${t}`).toContain(t);
    }
    // The mangled forms must be gone.
    const sources = new Set(snippets.map((s) => s.regexpSource));
    for (const bad of ['\\\\subset eq', '\\\\mathrm{i}nt', '\\\\mathrm{i}int', 'e\\\\xi sts', '\\\\xi i']) {
      expect(sources, `stale mangled trigger ${bad}`).not.toContain(bad);
    }
  });

  it('samples most regex triggers, so the check above is not vacuous', () => {
    const unsampled = snippets.filter(
      (s) => !s.trigger && sampleForRegex(s.regexpSource!) === null,
    );
    // Complex patterns (bra-ket, the fraction matcher) are checked by hand.
    expect(unsampled.length).toBeLessThanOrEqual(20);
    expect(snippets.length).toBeGreaterThan(200);
  });
});
