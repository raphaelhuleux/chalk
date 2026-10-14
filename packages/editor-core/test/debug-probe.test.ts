import { describe, it, expect, beforeEach } from 'vitest';
import type { EditorView } from '@codemirror/view';
import type { Language } from '../src/editor/setup';
import { langView } from './helpers/views';
import {
  probeHidden,
  probeWidgets,
  probeAtomic,
  expectedVisibleLines,
  domVisibleLines,
  type HiddenRange,
} from '../src/debug-probe';

/**
 * Reveal-oracle probes (src/debug-probe.ts) against every construct family,
 * in both languages, with the caret outside and inside each construct.
 *
 * These tests pin the observable reveal contract — exactly WHICH source spans
 * are hidden for a given caret — so a change to any reveal predicate
 * (revealSource's half-open window, the display-math line window, the command
 * window [cmdFrom, to+1), a fence's lineRevealed) turns them red.
 * Falsifiability was verified by flipping revealSource to `head <= to` and
 * watching the boundary cases below fail (see the commit message).
 *
 * Offsets are computed from the doc string (indexOf) rather than hardcoded,
 * so the assertions read as the geometry they claim.
 */

// The suite's own beforeEach clears the body.
const mount = (doc: string, language: Language): EditorView =>
  langView(doc, language, { clearBody: false, ensureTree: true, cursor: 0 });

function caretAt(view: EditorView, pos: number): void {
  view.dispatch({ selection: { anchor: pos } });
}

/** Hidden ranges reduced to extents for set comparisons. */
function extents(hidden: HiddenRange[]): Array<{ from: number; to: number; block: boolean }> {
  return hidden.map(({ from, to, block }) => ({ from, to, block }));
}

function oracleHolds(view: EditorView): void {
  expect(domVisibleLines(view)).toEqual(expectedVisibleLines(view.state.doc, probeHidden(view)));
}

beforeEach(() => {
  document.body.innerHTML = '';
});

// ---------------------------------------------------------------------------
//  tex
// ---------------------------------------------------------------------------

describe('tex inline math $…$', () => {
  const doc = 'Some $a+b$ inline\npark line\n';
  const from = doc.indexOf('$');
  const to = doc.indexOf('$', from + 1) + 1; // one past the closing $

  it('caret outside: the whole region is replaced', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from, to, block: false, widgetClass: 'MathWidget', widgetText: 'a+b' },
    ]);
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))[0]).toEqual({
      line: 1,
      text: 'Some  inline',
    });
    oracleHolds(view);
    view.destroy();
  });

  it('caret inside [from, to): nothing hidden; to is exclusive', () => {
    const view = mount(doc, 'tex');
    caretAt(view, from + 1);
    expect(probeHidden(view)).toEqual([]);
    caretAt(view, from); // on the opening $ counts as inside
    expect(probeHidden(view)).toEqual([]);
    caretAt(view, to); // one past the closing $ is outside again
    expect(probeHidden(view)).toHaveLength(1);
    oracleHolds(view);
    view.destroy();
  });
});

describe('tex display math \\[…\\]', () => {
  const doc = 'intro\n\\[\nE = mc^2\n\\]\nafter\n';
  const from = doc.indexOf('\\[');
  const to = doc.indexOf('\\]') + 2;

  it('caret outside: one block replace over the whole construct', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from, to, block: true, widgetClass: 'MathWidget', widgetText: '\nE = mc^2\n' },
    ]);
    // Lines 2-4 are fully block-covered: no visible-line entries for them.
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))).toEqual([
      { line: 1, text: 'intro' },
      { line: 5, text: 'after' },
      { line: 6, text: '' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on any line of the block (delimiters included): revealed, preview widget after it', () => {
    const view = mount(doc, 'tex');
    for (const pos of [doc.indexOf('E ='), from, doc.indexOf('\\]')]) {
      caretAt(view, pos);
      expect(probeHidden(view)).toEqual([]);
      expect(probeWidgets(view)).toEqual([
        { pos: to, side: 1, block: true, widgetClass: 'MathPreviewWidget' },
      ]);
    }
    oracleHolds(view);
    view.destroy();
  });
});

describe('tex equation environment', () => {
  const doc = 'intro\n\\begin{equation}\nE=mc^2\n\\end{equation}\nafter\n';
  const from = doc.indexOf('\\begin');
  const to = doc.indexOf('\\end{equation}') + '\\end{equation}'.length;

  it('caret outside: block replace including both fence lines', () => {
    const view = mount(doc, 'tex');
    expect(extents(probeHidden(view))).toEqual([{ from, to, block: true }]);
    expect(probeHidden(view)[0].widgetText).toBe('\\begin{equation}\nE=mc^2\n\\end{equation}');
    view.destroy();
  });

  it('caret on the \\end line: revealed (the line window spans the fences)', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('\\end{equation}'));
    expect(probeHidden(view)).toEqual([]);
    expect(probeWidgets(view)[0].widgetClass).toBe('MathPreviewWidget');
    oracleHolds(view);
    view.destroy();
  });
});

describe('tex \\textbf{} and the [cmdFrom, to+1) command window', () => {
  const doc = 'A \\textbf{bold} word\npark\n';
  const cmdFrom = doc.indexOf('\\textbf');
  const argFrom = doc.indexOf('bold');
  const close = doc.indexOf('}');

  it('caret outside: prefix and closing brace hidden, argument visible', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from: cmdFrom, to: argFrom, block: false, widgetClass: null, widgetText: null },
      { from: close, to: close + 1, block: false, widgetClass: null, widgetText: null },
    ]);
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))[0].text).toBe('A bold word');
    oracleHolds(view);
    view.destroy();
  });

  it('window boundaries: cmdFrom and the closing brace reveal, to+1 does not', () => {
    const view = mount(doc, 'tex');
    caretAt(view, cmdFrom);
    expect(probeHidden(view)).toEqual([]);
    caretAt(view, close); // ON the closing brace: still inside the window
    expect(probeHidden(view)).toEqual([]);
    caretAt(view, cmdFrom - 1);
    expect(probeHidden(view)).toHaveLength(2);
    caretAt(view, close + 1); // one past the brace: outside
    expect(probeHidden(view)).toHaveLength(2);
    view.destroy();
  });
});

describe('tex nested \\textbf{\\emph{…}}', () => {
  const doc = 'A \\textbf{\\emph{xy}} tail\npark\n';
  const bfFrom = doc.indexOf('\\textbf');
  const emFrom = doc.indexOf('\\emph');
  const xy = doc.indexOf('xy');
  const innerClose = doc.indexOf('}}');
  const outerClose = innerClose + 1;

  it('caret outside: abutting hides merge (prefixes; the }} pair)', () => {
    const view = mount(doc, 'tex');
    expect(extents(probeHidden(view))).toEqual([
      { from: bfFrom, to: xy, block: false }, // \textbf{ + \emph{ coalesced
      { from: innerClose, to: outerClose + 1, block: false }, // }} coalesced
    ]);
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))[0].text).toBe('A xy tail');
    oracleHolds(view);
    view.destroy();
  });

  it('caret inside the inner argument: both commands reveal', () => {
    const view = mount(doc, 'tex');
    caretAt(view, xy + 1);
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });

  it('caret on the outer brace only: outer reveals, inner stays concealed', () => {
    const view = mount(doc, 'tex');
    caretAt(view, outerClose); // inside [bfFrom, outerClose+1) but past [emFrom, innerClose+1)
    expect(extents(probeHidden(view))).toEqual([
      { from: emFrom, to: xy, block: false },
      { from: innerClose, to: innerClose + 1, block: false },
    ]);
    oracleHolds(view);
    view.destroy();
  });
});

describe('tex \\section{}', () => {
  const doc = '\\section{Model}\nbody\n';
  const argFrom = doc.indexOf('Model');
  const close = doc.indexOf('}');

  it('caret outside: prefix replaced by the number pill, brace hidden', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('body'));
    expect(probeHidden(view)).toEqual([
      { from: 0, to: argFrom, block: false, widgetClass: 'TexPillWidget', widgetText: '1' },
      { from: close, to: close + 1, block: false, widgetClass: null, widgetText: null },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret inside the title: raw source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, argFrom + 1);
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

describe('tex \\ref{} pill', () => {
  const doc = 'see \\ref{fig:model} here\npark\n';
  const cmdFrom = doc.indexOf('\\ref');
  const end = doc.indexOf(')') === -1 ? doc.indexOf('}') + 1 : 0;

  it('caret outside: ONE replace over the whole command, pill shows the key', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from: cmdFrom, to: end, block: false, widgetClass: 'TexPillWidget', widgetText: 'fig:model' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the key: raw source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('fig:'));
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

describe('tex \\footnote{}', () => {
  const doc = 'note\\footnote{small} here\npark\n';
  const cmdFrom = doc.indexOf('\\footnote');
  const end = doc.indexOf('}') + 1;

  it('caret outside: whole command collapses to the superscript number', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from: cmdFrom, to: end, block: false, widgetClass: 'TexPillWidget', widgetText: '1' },
    ]);
    view.destroy();
  });

  it('caret in the footnote text: raw source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('small'));
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

describe('tex theorem callout fences', () => {
  const doc = 'intro\n\\begin{theorem}\nbody text\n\\end{theorem}\nafter\n';
  const openFrom = doc.indexOf('\\begin');
  const openTo = doc.indexOf('}\nbody') + 1;
  // The close fence hides WITH its preceding newline (the collapsed-fence
  // idiom), so the row disappears instead of leaving a phantom blank.
  const closeHideFrom = doc.indexOf('body text') + 'body text'.length;
  const closeHideTo = doc.indexOf('\\end{theorem}') + '\\end{theorem}'.length;

  it('caret in the body: both fences hidden, label widget on the open line', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('body'));
    expect(probeHidden(view)).toEqual([
      {
        from: openFrom,
        to: openTo,
        block: false,
        widgetClass: 'CalloutLabelWidget',
        widgetText: 'Theorem',
      },
      { from: closeHideFrom, to: closeHideTo, block: false, widgetClass: null, widgetText: null },
    ]);
    // The hidden newline merges the close line into the body entry.
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))).toEqual([
      { line: 1, text: 'intro' },
      { line: 2, text: '' },
      { line: 3, text: 'body text' },
      { line: 5, text: 'after' },
      { line: 6, text: '' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the close fence line: the close fence reveals', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('\\end{theorem}') + 1);
    expect(extents(probeHidden(view))).toEqual([{ from: openFrom, to: openTo, block: false }]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the open fence line: the label widget yields to raw source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, openFrom + 1);
    expect(extents(probeHidden(view))).toEqual([
      { from: closeHideFrom, to: closeHideTo, block: false },
    ]);
    view.destroy();
  });
});

describe('tex itemize fences and \\item markers', () => {
  const doc = 'intro\n\\begin{itemize}\n\\item first\n\\item second\n\\end{itemize}\nafter\n';
  const openHideFrom = doc.indexOf('intro') + 'intro'.length; // preceding newline absorbed
  const openHideTo = doc.indexOf('}\n\\item') + 1;
  const item1 = doc.indexOf('\\item first');
  const item2 = doc.indexOf('\\item second');
  const closeHideFrom = doc.indexOf('second') + 'second'.length;
  const closeHideTo = doc.indexOf('\\end{itemize}') + '\\end{itemize}'.length;

  it('caret outside: fences hidden with their newlines, items replaced by markers', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from: openHideFrom, to: openHideTo, block: false, widgetClass: null, widgetText: null },
      { from: item1, to: item1 + 6, block: false, widgetClass: 'ItemMarkerWidget', widgetText: '•' },
      { from: item2, to: item2 + 6, block: false, widgetClass: 'ItemMarkerWidget', widgetText: '•' },
      { from: closeHideFrom, to: closeHideTo, block: false, widgetClass: null, widgetText: null },
    ]);
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))).toEqual([
      { line: 1, text: 'intro' },
      { line: 3, text: 'first' },
      { line: 4, text: 'second' },
      { line: 6, text: 'after' },
      { line: 7, text: '' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret in an \\item token: that marker reveals, the sibling stays', () => {
    const view = mount(doc, 'tex');
    caretAt(view, item1 + 1);
    const hidden = extents(probeHidden(view));
    expect(hidden).toContainEqual({ from: item2, to: item2 + 6, block: false });
    expect(hidden.some((h) => h.from === item1)).toBe(false);
    view.destroy();
  });

  it('caret on the close fence line: the fence reveals', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('\\end{itemize}') + 1);
    expect(extents(probeHidden(view)).some((h) => h.from === closeHideFrom)).toBe(false);
    oracleHolds(view);
    view.destroy();
  });
});

describe('tex beamer frame fences', () => {
  const doc =
    '\\documentclass{beamer}\n\\begin{document}\n\\begin{frame}{Title}\nbody\n\\end{frame}\n\\end{document}\n';
  const openFrom = doc.indexOf('\\begin{frame}');
  const openTo = doc.indexOf('{Title}') + '{Title}'.length;
  const closeFrom = doc.indexOf('\\end{frame}');
  const closeTo = closeFrom + '\\end{frame}'.length;

  it('caret in the body: header widget stands in, foot row keeps its (empty) row', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('body'));
    expect(probeHidden(view)).toEqual([
      {
        from: openFrom,
        to: openTo,
        block: false,
        widgetClass: 'FrameHeaderWidget',
        widgetText: 'Title',
      },
      { from: closeFrom, to: closeTo, block: false, widgetClass: null, widgetText: null },
    ]);
    // The \end{frame} ROW survives as the card's foot: an entry with no text,
    // not a dropped line (contrast the callout's newline-absorbing hide).
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))).toEqual([
      { line: 1, text: '\\documentclass{beamer}' },
      { line: 2, text: '\\begin{document}' },
      { line: 3, text: '' },
      { line: 4, text: 'body' },
      { line: 5, text: '' },
      { line: 6, text: '\\end{document}' },
      { line: 7, text: '' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the \\end{frame} line: the foot reveals its source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, closeFrom);
    expect(extents(probeHidden(view))).toEqual([{ from: openFrom, to: openTo, block: false }]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the \\begin{frame} line: the header reveals its source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, openFrom + 1);
    expect(extents(probeHidden(view))).toEqual([{ from: closeFrom, to: closeTo, block: false }]);
    view.destroy();
  });
});

describe('tex \\includegraphics', () => {
  const doc = 'fig below\n\\includegraphics[width=0.5\\textwidth]{fig.png}\npark\n';
  const from = doc.indexOf('\\includegraphics');
  const to = doc.indexOf('{fig.png}') + '{fig.png}'.length;

  it('caret outside: whole command replaced by the image widget', () => {
    const view = mount(doc, 'tex');
    expect(probeHidden(view)).toEqual([
      { from, to, block: false, widgetClass: 'ImageWidget', widgetText: 'fig.png' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret in the path: raw source', () => {
    const view = mount(doc, 'tex');
    caretAt(view, doc.indexOf('fig.png'));
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

// ---------------------------------------------------------------------------
//  md
// ---------------------------------------------------------------------------

describe('md inline math $…$', () => {
  const doc = 'Some $a+b$ inline\npark line\n';
  const from = doc.indexOf('$');
  const to = doc.indexOf('$', from + 1) + 1;

  it('caret outside: replaced by the KaTeX widget', () => {
    const view = mount(doc, 'md');
    expect(probeHidden(view)).toEqual([
      { from, to, block: false, widgetClass: 'KaTeXInlineWidget', widgetText: 'a+b' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret inside [from, to): raw source; to is exclusive', () => {
    const view = mount(doc, 'md');
    caretAt(view, from + 1);
    expect(probeHidden(view)).toEqual([]);
    caretAt(view, to);
    expect(probeHidden(view)).toHaveLength(1);
    view.destroy();
  });
});

describe('md $$ display block', () => {
  const doc = 'intro\n$$\nE=mc^2\n$$\nafter\n';
  const from = doc.indexOf('$$');
  const to = doc.indexOf('$$', from + 2) + 2;

  it('caret outside: one block replace, block-covered lines yield no entries', () => {
    const view = mount(doc, 'md');
    expect(probeHidden(view)).toEqual([
      { from, to, block: true, widgetClass: 'KaTeXBlockWidget', widgetText: 'E=mc^2' },
    ]);
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))).toEqual([
      { line: 1, text: 'intro' },
      { line: 5, text: 'after' },
      { line: 6, text: '' },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on any block line (fences included): revealed, preview widget after it', () => {
    const view = mount(doc, 'md');
    for (const pos of [doc.indexOf('E='), from]) {
      caretAt(view, pos);
      expect(probeHidden(view)).toEqual([]);
      expect(probeWidgets(view)).toEqual([
        // Same class as the tex probe above: one shared preview widget now
        // serves both languages (display-math-core.ts).
        { pos: to, side: 1, block: true, widgetClass: 'MathPreviewWidget' },
      ]);
    }
    oracleHolds(view);
    view.destroy();
  });
});

describe('md heading marker stays visible by design', () => {
  it('no hidden ranges whether the caret is in or out of the heading', () => {
    const doc = '# Heading one\nbody\n';
    const view = mount(doc, 'md');
    for (const pos of [doc.indexOf('body'), 2]) {
      caretAt(view, pos);
      expect(probeHidden(view)).toEqual([]);
      expect(expectedVisibleLines(view.state.doc, probeHidden(view))[0].text).toBe(
        '# Heading one',
      );
    }
    oracleHolds(view);
    view.destroy();
  });

  it('only a trailing {#sec-…} attribute hides, and only while the caret is out', () => {
    const doc = '# Setup {#sec-setup}\nbody\n';
    const view = mount(doc, 'md');
    caretAt(view, doc.indexOf('body'));
    const attrFrom = doc.indexOf(' {#sec-setup}');
    expect(extents(probeHidden(view))).toEqual([
      { from: attrFrom, to: doc.indexOf('}') + 1, block: false },
    ]);
    caretAt(view, 2);
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

// The four marker-pair inline spans share one shape: the delimiters hide, the
// text stays, and a caret anywhere in [from, to) restores the raw source.
for (const [name, doc, open, close] of [
  ['bold', 'Some **bold** text\npark\n', '**', '**'],
  ['italic', 'Some *ital* text\npark\n', '*', '*'],
  ['code', 'Some `code` text\npark\n', '`', '`'],
  ['strike', 'Some ~~gone~~ text\npark\n', '~~', '~~'],
  ['highlight', 'Some ==mark== text\npark\n', '==', '=='],
] as const) {
  describe(`md ${name}`, () => {
    const openFrom = doc.indexOf(open);
    const closeFrom = doc.lastIndexOf(close, doc.indexOf(' text'));

    it('caret outside: both delimiters hidden', () => {
      const view = mount(doc, 'md');
      expect(extents(probeHidden(view))).toEqual([
        { from: openFrom, to: openFrom + open.length, block: false },
        { from: closeFrom, to: closeFrom + close.length, block: false },
      ]);
      oracleHolds(view);
      view.destroy();
    });

    it('caret inside: raw markers back', () => {
      const view = mount(doc, 'md');
      caretAt(view, openFrom + open.length + 1);
      expect(probeHidden(view)).toEqual([]);
      view.destroy();
    });
  });
}

describe('md link', () => {
  const doc = 'A [link](https://x.y) here\npark\n';

  it('caret outside: [ and ](url) hidden, text visible', () => {
    const view = mount(doc, 'md');
    expect(extents(probeHidden(view))).toEqual([
      { from: doc.indexOf('['), to: doc.indexOf('[') + 1, block: false },
      { from: doc.indexOf(']'), to: doc.indexOf(')') + 1, block: false },
    ]);
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))[0].text).toBe('A link here');
    oracleHolds(view);
    view.destroy();
  });

  it('caret in the link text: raw source', () => {
    const view = mount(doc, 'md');
    caretAt(view, doc.indexOf('link') + 1);
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

describe('md image', () => {
  const doc = 'An ![alt](img.png) here\npark\n';

  it('caret outside: whole ![alt](src) replaced by the image widget', () => {
    const view = mount(doc, 'md');
    expect(probeHidden(view)).toEqual([
      {
        from: doc.indexOf('!['),
        to: doc.indexOf(')') + 1,
        block: false,
        widgetClass: 'ImageWidget',
        widgetText: 'img.png',
      },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret inside: raw source', () => {
    const view = mount(doc, 'md');
    caretAt(view, doc.indexOf('alt'));
    expect(probeHidden(view)).toEqual([]);
    view.destroy();
  });
});

describe('md blockquote', () => {
  it('the > marker is styled, never hidden', () => {
    const doc = '> quoted line\npark\n';
    const view = mount(doc, 'md');
    for (const pos of [doc.indexOf('park'), 2]) {
      caretAt(view, pos);
      expect(probeHidden(view)).toEqual([]);
    }
    oracleHolds(view);
    view.destroy();
  });
});

describe('md ::: callout fences', () => {
  const doc = 'intro\n::: {.callout-note}\nnote body\n:::\nafter\n';
  const openFrom = doc.indexOf(':::');
  const openTo = doc.indexOf('}\nnote') + 1;
  const closeHideFrom = doc.indexOf('note body') + 'note body'.length;
  const closeHideTo = doc.indexOf(':::\nafter') + 3;

  it('caret in the body: label widget on the open fence, close fence absorbed', () => {
    const view = mount(doc, 'md');
    caretAt(view, doc.indexOf('note body'));
    expect(probeHidden(view)).toEqual([
      {
        from: openFrom,
        to: openTo,
        block: false,
        widgetClass: 'CalloutLabelWidget',
        widgetText: 'Note',
      },
      { from: closeHideFrom, to: closeHideTo, block: false, widgetClass: null, widgetText: null },
    ]);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the close fence line: the ::: reveals', () => {
    const view = mount(doc, 'md');
    caretAt(view, closeHideFrom + 2);
    expect(extents(probeHidden(view))).toEqual([{ from: openFrom, to: openTo, block: false }]);
    expect(
      expectedVisibleLines(view.state.doc, probeHidden(view)).some(
        (l) => l.line === 4 && l.text === ':::',
      ),
    ).toBe(true);
    oracleHolds(view);
    view.destroy();
  });

  it('caret on the open fence line: the raw fence comes back', () => {
    const view = mount(doc, 'md');
    caretAt(view, openFrom + 1);
    expect(extents(probeHidden(view))).toEqual([
      { from: closeHideFrom, to: closeHideTo, block: false },
    ]);
    view.destroy();
  });
});

describe('md GFM table', () => {
  const doc = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\npark\n';
  const to = doc.indexOf('|\n\n') + 1;

  it('the table is one block replace AND one atomic range', () => {
    const view = mount(doc, 'md');
    caretAt(view, doc.indexOf('park'));
    expect(extents(probeHidden(view))).toEqual([{ from: 0, to, block: true }]);
    expect(probeHidden(view)[0].widgetClass).toBe('TableWidget');
    expect(probeAtomic(view)).toEqual([{ from: 0, to }]);
    // All three source rows are block-covered: no visible-line entries.
    expect(expectedVisibleLines(view.state.doc, probeHidden(view))).toEqual([
      { line: 4, text: '' },
      { line: 5, text: 'park' },
      { line: 6, text: '' },
    ]);
    oracleHolds(view);
    view.destroy();
  });
});
