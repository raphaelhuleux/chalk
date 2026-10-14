import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { LABELS } from '../src/editor/callout-core';

// Audit check A, invariants 1, 6 (CSS half), 7 — previously verified only by
// hand or Playwright. These tests read the stylesheets as text and pin:
//  - PADDING-not-margin for every block element inside .cm-content
//    (margins are invisible to CM6's height map; a vertical margin desyncs
//    posAtCoords for the whole document below — commits 87a3e0b, bd4811d).
//  - The caret's exact rendering values (commit 0ad093d + fc2959d).

const stylesDir = join(__dirname, '../src/styles');
const read = (f: string): string => readFileSync(join(stylesDir, f), 'utf8');
const chalkTheme = readFileSync(
  join(__dirname, '../../../web/src/chalk-theme.css'),
  'utf8',
);

/**
 * Declaration blocks that style the element ITSELF (last selector compound
 * contains `selector`). Descendant rules (`.cm-math-display .katex-display`)
 * are excluded on purpose: a margin on an inner element stays inside the
 * widget's border box and cannot desync the height map.
 */
function blocksFor(css: string, selector: string): string[] {
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const out: string[] = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(stripped)) !== null) {
    const selectors = m[1].split(',').map((s) => s.trim());
    const stylesElementItself = selectors.some((s) => {
      const lastCompound = s.split(/[\s>+~]+/).pop() ?? '';
      return lastCompound.includes(selector);
    });
    if (stylesElementItself) out.push(m[2]);
  }
  return out;
}

const isZeroLength = (v: string): boolean => /^0[a-z%]*$/.test(v.trim());

function hasVerticalMargin(block: string): boolean {
  // margin-top/bottom with a nonzero value…
  for (const m of block.matchAll(/margin-(top|bottom)\s*:\s*([^;]+)/g)) {
    if (!isZeroLength(m[2])) return true;
  }
  // …or shorthand margin with a nonzero vertical component.
  const shorthand = /(?:^|;|\s)margin\s*:\s*([^;]+)/.exec(block);
  if (!shorthand) return false;
  const parts = shorthand[1].trim().split(/\s+/);
  const vertical = [parts[0], parts.length >= 3 ? parts[2] : parts[0]];
  return vertical.some((v) => v !== 'auto' && !isZeroLength(v));
}

describe('height-map guardrail: padding, never vertical margin (inv 6/7)', () => {
  const cases: Array<[string, string]> = [
    ['table.css', '.cm-live-table-wrap'],
    ['math.css', '.cm-math-display'],
    ['math.css', '.cm-math-preview'],
    ['editor.css', '.cm-tex-math-display'],
    ['editor.css', '.cm-tex-math-preview'],
    ['callout.css', '.cm-callout'],
    ['slide.css', '.cm-slide'],
    ['mermaid.css', '.cm-mermaid'],
  ];

  it.each(cases)('%s: %s has no vertical margin', (file, selector) => {
    const blocks = blocksFor(read(file), selector);
    expect(blocks.length).toBeGreaterThan(0);
    for (const block of blocks) {
      expect(hasVerticalMargin(block), `vertical margin in ${selector}:\n${block}`).toBe(false);
    }
  });

  it('table.css: .cm-live-table-wrap uses padding for vertical space (inv 7)', () => {
    const blocks = blocksFor(read('table.css'), '.cm-live-table-wrap');
    expect(blocks.some((b) => /padding\s*:\s*[^;]*em/.test(b))).toBe(true);
  });

  it('display math keeps its padding rules (inv 6)', () => {
    expect(blocksFor(read('math.css'), '.cm-math-display').join(';')).toMatch(/padding/);
    expect(blocksFor(read('editor.css'), '.cm-tex-math-display').join(';')).toMatch(/padding/);
  });

  it('overflow containment stays on display math and previews', () => {
    for (const [file, sel] of [
      ['math.css', '.cm-math-display'],
      ['math.css', '.cm-math-preview'],
      ['editor.css', '.cm-tex-math-display'],
      ['editor.css', '.cm-tex-math-preview'],
    ] as const) {
      const joined = blocksFor(read(file), sel).join(';');
      expect(joined, `${file} ${sel}`).toMatch(/contain\s*:\s*inline-size/);
    }
  });
});

/**
 * Every recognised callout type must have a palette. A type reaches the
 * renderer as soon as it is added to LABELS, but its accent and tint live in
 * CSS, and a missing pair does not fail loudly: `--callout-accent` is simply
 * undefined, so `border-left: 3px solid var(--callout-accent)` and
 * `background: var(--callout-bg)` are both dropped as invalid and the box
 * renders with no bar and no tint. That is how beamer's block family shipped
 * invisible — recognised, numbered, boxed, and completely unstyled.
 */
describe('callout palette coverage', () => {
  it('every type in LABELS has an accent and a tint in callout.css', () => {
    const css = read('callout.css').replace(/\/\*[\s\S]*?\*\//g, '');
    const styled = new Set<string>();
    const re = /([^{}]+)\{([^{}]*)\}/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(css)) !== null) {
      if (!/--callout-accent\s*:/.test(m[2]) || !/--callout-bg\s*:/.test(m[2])) continue;
      for (const sel of m[1].split(',')) {
        const hit = /\.cm-callout-([a-z]+)/.exec(sel.trim());
        if (hit) styled.add(hit[1]);
      }
    }
    const missing = Object.keys(LABELS).filter((type) => !styled.has(type));
    expect(missing, `callout types with no palette: ${missing.join(', ')}`).toEqual([]);
  });
});

/** Blocks whose full selector list contains `needle` (multi-compound OK). */
function blocksContaining(css: string, needle: string): string[] {
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const out: string[] = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(stripped)) !== null) {
    if (m[1].includes(needle)) out.push(m[2]);
  }
  return out;
}

describe('image widget caret box (R-V1: FINDINGS.md #4)', () => {
  // CM6's moveVertically probes textHeight/2 below the current row, so a
  // widget row SHORTER than that is stepped over and becomes vertically
  // unreachable; an image whose asset has not resolved (or failed, or
  // renders tiny) had no box at all. The stand-in must always be at least a
  // caret-sized box: one text line tall, one character wide.
  it('.cm-live-image keeps its minimum caret-sized box', () => {
    const joined = blocksContaining(read('editor.css'), '.cm-live-image').join(';');
    expect(joined).toMatch(/min-height\s*:\s*[^;0]/);
    expect(joined).toMatch(/min-width\s*:\s*[^;0]/);
  });
});

describe('caret rendering lock (inv 1: 0ad093d + fc2959d)', () => {
  it('caret is a 2.5px bar stretched symmetrically, never squashed', () => {
    const blocks = blocksContaining(chalkTheme, '.editor-host .cm-cursor');
    const joined = blocks.join(';');
    expect(joined).toMatch(/border-left-width\s*:\s*2\.5px/);
    const scale = /scaleY\(([\d.]+)\)/.exec(joined);
    expect(scale).not.toBeNull();
    expect(Number(scale![1])).toBeGreaterThanOrEqual(1); // stretch, not squash
  });

  it('blink is the 1.8s chalk-caret animation on focus, layer default off', () => {
    expect(
      blocksContaining(chalkTheme, '.editor-host .cm-cursorLayer').join(';'),
    ).toMatch(/animation\s*:\s*none/);
    expect(
      blocksContaining(chalkTheme, '.cm-focused .cm-cursor').join(';'),
    ).toMatch(/chalk-caret\s+1\.8s/);
  });
});

describe('mixed view mode styling exists (a dropped rule renders invisibly)', () => {
  it('editor.css dims syntax and styles the crossref key', () => {
    const css = read('editor.css');
    expect(css).toMatch(/\.cm-syntax-dim\s*\{[^}]*opacity/);
    expect(css).toMatch(/\.cm-crossref-key\s*\{/);
  });

  it('callout.css draws the number chip as a ::after with no height', () => {
    const css = read('callout.css');
    const chip = /\.cm-line\.cm-callout-top\[data-callout\]::after\s*\{([^}]*)\}/.exec(css);
    expect(chip).not.toBeNull();
    expect(chip![1]).toContain('content: attr(data-callout)');
    expect(chip![1]).toContain('position: absolute');
    expect(chip![1]).toContain('pointer-events: none');
  });

  it('list-layout.css colors the raw \\item token', () => {
    expect(read('list-layout.css')).toMatch(/\.cm-tex-item-source\s*\{/);
  });
});
