import { describe, it, expect } from 'vitest';
import { EditorState } from '@codemirror/state';
import { Decoration, type DecorationSet, type EditorView } from '@codemirror/view';
import { markdown } from '@codemirror/lang-markdown';
import { Strikethrough, Table, TaskList } from '@lezer/markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { glueEnd, glueStart } from '../src/editor/punctuation-glue';
import { buildLivePreviewDecorations } from '../src/editor/md-live-preview';
import { mathSyntax, _testing } from '../src/editor/md-math-plugin';
import { highlightSyntax } from '../src/editor/md-highlight-plugin';
import { frontmatterSyntax } from '../src/editor/md-frontmatter';

/**
 * Trailing punctuation must not wrap onto a row of its own (`$V_t(a)$!`,
 * `*state*,`). Both plugins glue it to the construct with a `white-space:
 * nowrap` mark — see punctuation-glue.ts for the atomic-inline mechanism, and
 * the "trailing punctuation never wraps alone" browser scenario for the
 * geometry, which jsdom cannot see.
 *
 * What jsdom CAN see is the decoration layer, and that is where this bug
 * actually broke on 2026-09-04: the glue mark was added before the replace it
 * had to contain, which violates `RangeSetBuilder`'s (from, startSide) order.
 * The builder threw, CM6 caught it, logged, and DISABLED the whole plugin —
 * every formula in the document silently fell back to raw `$…$`. Nothing in
 * the browser suite failed for the right reason, and a geometry check counting
 * orphaned punctuation PASSED, because an editor rendering raw text has no
 * atomic box to orphan anything after. So the throw is asserted here, cheaply
 * and directly, and the ordering contract it depends on is pinned below.
 */

const buildMath = _testing.buildInlineMathDecorations;

function stateFor(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [
      markdown({
        extensions: [frontmatterSyntax, mathSyntax, highlightSyntax, Strikethrough, TaskList, Table],
      }),
    ],
  });
  ensureSyntaxTree(state, doc.length, 5000);
  return state;
}

/** The two things both builders read off the view. */
function viewFor(doc: string): EditorView {
  const state = stateFor(doc);
  return { state, visibleRanges: [{ from: 0, to: doc.length }] } as unknown as EditorView;
}

interface Range {
  from: number;
  to: number;
  cls: string | undefined;
  replace: boolean;
  startSide: number;
}

function ranges(set: DecorationSet): Range[] {
  const out: Range[] = [];
  const iter = set.iter();
  while (iter.value) {
    const spec = iter.value.spec as { class?: string; widget?: unknown };
    out.push({
      from: iter.from,
      to: iter.to,
      cls: spec.class,
      // A replace decoration is a point: CM6 models it with `point === true`.
      replace: iter.value.point,
      startSide: iter.value.startSide,
    });
    iter.next();
  }
  return out;
}

const glueOf = (set: DecorationSet, cls: string): Range[] =>
  ranges(set).filter((r) => r.cls === cls);

// ---------------------------------------------------------------------------

describe('glueEnd', () => {
  const at = (doc: string, to: number) => glueEnd(stateFor(doc), to);

  it('reaches over a run of trailing punctuation', () => {
    expect(at('x!', 1)).toBe(2);
    expect(at('x,', 1)).toBe(2);
    expect(at('x?!', 1)).toBe(3);
  });

  it('stops at the first character outside the set', () => {
    expect(at('x, y', 1)).toBe(2); // the space is not glue
    expect(at('x y', 1)).toBe(1);
  });

  it('returns `to` unchanged when nothing follows', () => {
    expect(at('x', 1)).toBe(1);
  });

  it('never runs past the end of the line', () => {
    // A decoration spanning a line break is one CM6 refuses from a ViewPlugin.
    // TWO independent guards keep that from happening — the `lineEnd` clamp
    // and the fact that `\n` is not a glue character — so removing either one
    // alone leaves this green. It is here to pin the invariant, not either
    // guard: verified to fail when both are removed together.
    expect(at('x\n.next', 1)).toBe(1);
  });

  it('caps the run so a row of dots is not swallowed whole', () => {
    expect(at('x......', 1)).toBe(4); // 3 chars max
  });
});

describe('glueStart', () => {
  const at = (doc: string, before: number, floor: number) =>
    glueStart(stateFor(doc), before, floor);

  it('reaches back to the start of the last word', () => {
    //            0123456789
    expect(at('one two xy', 10, 0)).toBe(8);
  });

  it('never passes the floor', () => {
    // The floor is the construct's own start: reaching further back would put
    // the mark's `from` behind decorations a previous sibling already emitted,
    // which is the RangeSetBuilder ordering violation all over again.
    expect(at('one two xy', 10, 9)).toBe(9);
  });

  it('stops at the start of the line', () => {
    expect(at('a\nword', 6, 0)).toBe(2);
  });

  it('returns `before` when whitespace is already there', () => {
    expect(at('one ', 4, 0)).toBe(4);
  });
});

// ---------------------------------------------------------------------------

describe('the CM6 ordering contract the glue relies on', () => {
  /**
   * `startSide` does two jobs at once, and the glue needs both: it is the tie
   * break `RangeSetBuilder` sorts by at an equal `from`, AND it decides which
   * marks are open when the content builder reaches a point — a mark only
   * wraps a widget it opened BEFORE. If a CM6 upgrade ever moves these
   * numbers, this test says so instead of the app quietly losing the glue (or
   * every construct in the document, if the order flips the other way).
   */
  it('puts an inclusive-start mark ahead of a replace at the same position', () => {
    const glue = Decoration.mark({ class: 'cm-live-glue', inclusiveStart: true });
    const plain = Decoration.mark({ class: 'cm-live-italic' });
    const replace = Decoration.replace({});
    expect(glue.startSide).toBeLessThan(replace.startSide);
    expect(replace.startSide).toBeLessThan(plain.startSide);
  });
});

// ---------------------------------------------------------------------------

describe('math glue', () => {
  it('marks the formula and the punctuation after it', () => {
    const doc = 'and $V_t(a)$! more';
    const g = glueOf(buildMath(viewFor(doc)), 'cm-math-glue');
    expect(g).toHaveLength(1);
    expect(doc.slice(g[0].from, g[0].to)).toBe('$V_t(a)$!');
  });

  it('opens before the replace it has to contain', () => {
    // Not a detail: a mark CM6 opens after the point is not in the `active`
    // list it wraps the widget tile in, so the widget renders outside the
    // nowrap box and the punctuation orphans exactly as before.
    const set = buildMath(viewFor('and $x$! more'));
    const [glue] = glueOf(set, 'cm-math-glue');
    const replace = ranges(set).find((r) => r.replace);
    expect(replace).toBeDefined();
    expect(glue.from).toBe(replace!.from);
    expect(glue.startSide).toBeLessThan(replace!.startSide);
    expect(glue.to).toBeGreaterThan(replace!.to);
  });

  it('adds no mark when a space separates the punctuation', () => {
    expect(glueOf(buildMath(viewFor('and $x$ ! more')), 'cm-math-glue')).toHaveLength(0);
  });

  it('adds no mark while the caret reveals the source', () => {
    const doc = 'and $x$! more';
    const state = stateFor(doc).update({ selection: { anchor: 5 } }).state;
    const view = { state, visibleRanges: [{ from: 0, to: doc.length }] } as unknown as EditorView;
    expect(glueOf(buildMath(view), 'cm-math-glue')).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------

describe('markdown construct glue', () => {
  // Every construct whose delimiters are concealed, and so renders CM6
  // `.cm-widgetBuffer` <img> anchors the browser may wrap after.
  const CONSTRUCTS: Array<[string, string]> = [
    ['bold', '**Households**,'],
    ['italic', '*state*,'],
    ['strikethrough', '~~gone~~,'],
    ['highlight', '==marked==,'],
    ['inline code', '`code`,'],
  ];

  for (const [label, src] of CONSTRUCTS) {
    it(`glues the punctuation after ${label}`, () => {
      const doc = `see ${src} then`;
      const g = glueOf(buildLivePreviewDecorations(viewFor(doc)), 'cm-live-glue');
      expect(g).toHaveLength(1);
      expect(doc.slice(g[0].from, g[0].to)).toBe(src);
    });

    it(`opens the ${label} glue before the closing replace`, () => {
      const doc = `see ${src} then`;
      const set = buildLivePreviewDecorations(viewFor(doc));
      const [glue] = glueOf(set, 'cm-live-glue');
      const closing = ranges(set).filter((r) => r.replace).pop();
      expect(closing).toBeDefined();
      expect(glue.from).toBeLessThanOrEqual(closing!.from);
      expect(glue.to).toBeGreaterThan(closing!.to);
      if (glue.from === closing!.from) {
        expect(glue.startSide).toBeLessThan(closing!.startSide);
      }
    });
  }

  it('reaches back only to the last word of a long run', () => {
    // Gluing the whole construct would make a long emphasised phrase
    // unbreakable and overflow the measure; gluing only the delimiter and the
    // punctuation would leave the box OPENING with an atomic <img>, whose
    // wrap opportunity lives outside the box and strands the comma anyway.
    const doc = 'Consider *a long emphasised clause that runs on*, then more.';
    const [glue] = glueOf(buildLivePreviewDecorations(viewFor(doc)), 'cm-live-glue');
    expect(doc.slice(glue.from, glue.to)).toBe('on*,');
  });

  it('adds no mark when a space separates the punctuation', () => {
    expect(
      glueOf(buildLivePreviewDecorations(viewFor('see *state* , then')), 'cm-live-glue'),
    ).toHaveLength(0);
  });

  it('adds no mark while the caret reveals the source', () => {
    const doc = 'see *state*, then';
    const state = stateFor(doc).update({ selection: { anchor: 6 } }).state;
    const view = { state, visibleRanges: [{ from: 0, to: doc.length }] } as unknown as EditorView;
    expect(glueOf(buildLivePreviewDecorations(view), 'cm-live-glue')).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------

describe('neither builder throws (a throw disables the plugin silently)', () => {
  const PUNCT = ['!', '?', '.', ',', ';', ':', ')', ']', '}', '"', "'", '”', '’', '?!', '...', ''];
  const CARRIERS = [
    '$x$',
    '$V_t(a_{t-1})$',
    '**bold**',
    '*italic*',
    '***both***',
    '~~gone~~',
    '==marked==',
    '`code`',
    '[link](https://example.com)',
    '**bold with *nested* inside**',
  ];

  for (const carrier of CARRIERS) {
    for (const punct of PUNCT) {
      const doc = `lead ${carrier}${punct} trail`;
      it(`builds ${JSON.stringify(doc)}`, () => {
        const view = viewFor(doc);
        expect(() => buildLivePreviewDecorations(view)).not.toThrow();
        expect(() => buildMath(view)).not.toThrow();
      });
    }
  }

  // Shapes with no whitespace between constructs: `glueStart` scans backwards
  // over non-whitespace, so an unfloored version would reach behind ranges an
  // earlier sibling already emitted and break the builder's ordering.
  const ADJACENT = [
    '*a*,*b*,',
    '**a**,*b*.',
    '$x$,$y$!',
    '*a*$x$,',
    '`a`,`b`,',
    'word*a*, word',
    '==a==,~~b~~;',
    '*a*,,,,,,b',
  ];
  for (const doc of ADJACENT) {
    it(`builds adjacent shape ${JSON.stringify(doc)}`, () => {
      const view = viewFor(doc);
      expect(() => buildLivePreviewDecorations(view)).not.toThrow();
      expect(() => buildMath(view)).not.toThrow();
    });
  }

  it('builds a document that mixes both plugins on one line', () => {
    const doc =
      "To obtain $V'_{t+1}(a_{t})$, take the derivative with respect to the *state*, $a_{t-1}$:\n" +
      '\n' +
      '- **Households**: assuming $\\beta R =1$, this becomes $$ c_0 = r h_0 $$ ' +
      '$\\Rightarrow$ consumption is the annuity value (smoothing!)\n';
    const view = viewFor(doc);
    expect(() => buildLivePreviewDecorations(view)).not.toThrow();
    expect(() => buildMath(view)).not.toThrow();
  });
});
