/**
 * Cell composer for the discovery matrix.
 *
 * Places every catalogue construct (catalogue.mjs) into its declared
 * contexts, shifting the construct's structural metadata to absolute
 * document offsets — the composer knows where it put things, so no cell
 * ever consults the engine for its own extents.
 *
 * Contexts (trimmed per construct in the catalogue rather than sampled):
 *   start / mid / end      construct at the start / middle / end of a prose line
 *   mid-w40                the mid doc at wrap width 40 (wrap interplay)
 *   adjacent               two instances of the construct on one line
 *   own-line               the construct is the whole line
 *   callout-body           inline construct inside a callout body line
 *   list-item              inline construct inside a list item line
 *   wrapped                inline construct inside wrapped prose at width 40
 *   above-display          construct's line directly above a display block
 *   plain / plain-narrow   block construct between park lines (narrow viewport)
 *   wrapped-above          wrapped prose directly above the block, width 40
 *   absorb-callout         block is the LAST body element of a callout
 *   absorb-list            block is the last element of an itemize (tex)
 *   absorb-nested-list     block ends an itemize nested in an enumerate (tex)
 *   callout-mid            block inside a callout with body after it (md)
 *   list-block             block indented as a list-item continuation (md)
 *   beamer                 beamer frame with its documentclass header (tex)
 *   tail                   block at the document tail (md unclosed $$)
 *
 * Widths: 80 (default) or 40 (wrapped contexts and mid-w40).
 * Viewports: desktop 760x900 (default) or narrow 506x834 (plain-narrow).
 * Cell ids are stable: `tex/inline-math/mid/w80/desktop`.
 */
import { CONSTRUCTS } from './catalogue.mjs';

export const VIEWPORTS = {
  desktop: { width: 760, height: 900 },
  narrow: { width: 506, height: 834 },
};

const PARK_TOP = 'park park park park park one';
const PARK_BOT = 'park park park park park two';
const WRAP_LEAD = 'prose that wraps across the narrow measure ';
const WRAP_TAIL = ' and keeps on wrapping well past the fold here';
const WRAP_PARA =
  'this wrapped paragraph is long enough to occupy several visual rows at width forty so the walk matters';

/** Shift one catalogue instance to absolute offsets.
 *  `base` = char offset of the snippet start; `lineBase` = number of doc
 *  lines before the snippet's first line; `lineStarts` = char offset of each
 *  doc line start (0-based index = 0-based line). */
function absolutize(inst, base, lineBase, lineStarts) {
  const out = { ...inst };
  const shift = (k) => {
    if (typeof out[k] === 'number') out[k] += base;
  };
  switch (inst.kind) {
    case 'inline-math':
    case 'display-math':
    case 'display-unclosed':
    case 'whole-replace':
      shift('from');
      shift('to');
      break;
    case 'command':
    case 'pill':
      shift('cmdFrom');
      shift('argFrom');
      shift('argTo');
      break;
    case 'href':
      shift('cmdFrom');
      shift('textFrom');
      shift('textTo');
      break;
    case 'marker-pair':
      shift('nodeFrom');
      shift('nodeTo');
      out.hides = inst.hides.map((h) => ({ from: h.from + base, to: h.to + base }));
      break;
    case 'heading-attr':
      shift('nodeFrom');
      shift('nodeTo');
      shift('attrFrom');
      break;
    case 'callout':
    case 'frame':
      out.openLine = lineBase + inst.openLine + 1; // 1-based doc lines
      out.closeLine = lineBase + inst.closeLine + 1;
      break;
    case 'list':
      out.openLine = lineBase + inst.openLine + 1;
      out.closeLine = lineBase + inst.closeLine + 1;
      out.items = inst.items.map((it) => {
        const docLine = lineBase + it.line + 1;
        const start = lineStarts[docLine - 1];
        return { line: docLine, from: start + it.from, to: start + it.to };
      });
      break;
    case 'table':
      out.fromLine = lineBase + inst.fromLine + 1;
      out.toLine = lineBase + inst.toLine + 1;
      break;
    case 'none':
      break;
    default:
      throw new Error(`compose: unknown instance kind ${inst.kind}`);
  }
  if (inst.clickTarget) out.clickTarget = { ...inst.clickTarget };
  return out;
}

function lineStartsOf(doc) {
  const starts = [0];
  for (let i = 0; i < doc.length; i++) if (doc[i] === '\n') starts.push(i + 1);
  return starts;
}

/** Build one cell from doc LINES plus placements:
 *  placements = [{construct, lineIndex (0-based line of snippet start),
 *                 colOffset (chars before the snippet on that line)}]. */
function makeCell(construct, context, lines, placements, { width = 80, viewport = 'desktop' } = {}) {
  const doc = lines.join('\n') + '\n';
  const lineStarts = lineStartsOf(doc);
  const instances = [];
  for (const p of placements) {
    const base = lineStarts[p.lineIndex] + (p.colOffset ?? 0);
    for (const inst of p.construct.instances) {
      instances.push({
        ...absolutize(inst, base, p.lineIndex, lineStarts),
        construct: p.construct.name,
      });
    }
  }
  return {
    id: `${construct.language}/${construct.name}/${context}/w${width}/${viewport}`,
    language: construct.language,
    construct: construct.name,
    context,
    doc,
    width,
    viewport,
    instances,
  };
}

/** Wrapper snippets used by the composed contexts, as pseudo-constructs so
 *  their instances ride the same absolutize path. */
const WRAPPERS = {
  texCallout: {
    name: 'theorem-wrapper',
    instances: [{ kind: 'callout', rule: 'R-T6', openLine: 0, closeLine: 2, clickTarget: null }],
  },
  mdCallout: {
    name: 'callout-wrapper',
    instances: [{ kind: 'callout', rule: 'R-M8', openLine: 0, closeLine: 2, clickTarget: null }],
  },
  texList: {
    name: 'itemize-wrapper',
    instances: [
      {
        kind: 'list',
        rule: 'R-T7',
        openLine: 0,
        closeLine: 2,
        openHasArgs: false,
        items: [{ line: 1, from: 0, to: 6 }],
        clickTarget: null,
      },
    ],
  },
};

/** Wrapper with an explicit closeLine (absorb contexts vary the body length). */
function wrapperWithClose(base, closeLine, items) {
  const inst = { ...base.instances[0], closeLine };
  if (items) inst.items = items;
  return { name: base.name, instances: [inst] };
}

function composeInline(construct) {
  const T = construct.text;
  const cells = [];
  const lang = construct.language;
  const mk = (context, lines, placements, opts) =>
    cells.push(makeCell(construct, context, lines, placements, opts));

  for (const context of construct.contexts) {
    switch (context) {
      case 'start':
        mk('start', [PARK_TOP, `${T} tail words here`, PARK_BOT], [
          { construct, lineIndex: 1, colOffset: 0 },
        ]);
        break;
      case 'mid':
      case 'mid-w40': {
        const lead = 'lead words ';
        mk(context, [PARK_TOP, `${lead}${T} tail words`, PARK_BOT], [
          { construct, lineIndex: 1, colOffset: lead.length },
        ], context === 'mid-w40' ? { width: 40 } : {});
        break;
      }
      case 'end': {
        const lead = 'lead words here ';
        mk('end', [PARK_TOP, `${lead}${T}`, PARK_BOT], [
          { construct, lineIndex: 1, colOffset: lead.length },
        ]);
        break;
      }
      case 'adjacent': {
        const lead = 'lead ';
        const mid = ' and ';
        mk('adjacent', [PARK_TOP, `${lead}${T}${mid}${T} tail`, PARK_BOT], [
          { construct, lineIndex: 1, colOffset: lead.length },
          { construct, lineIndex: 1, colOffset: lead.length + T.length + mid.length },
        ]);
        break;
      }
      case 'own-line':
        mk('own-line', [PARK_TOP, T, PARK_BOT], [{ construct, lineIndex: 1, colOffset: 0 }]);
        break;
      case 'callout-body': {
        const lead = 'lead ';
        const inner = `${lead}${T} tail`;
        const wrapLines =
          lang === 'tex'
            ? ['\\begin{theorem}', inner, '\\end{theorem}']
            : ['::: {.callout-note}', inner, ':::'];
        const wrapper = lang === 'tex' ? WRAPPERS.texCallout : WRAPPERS.mdCallout;
        mk('callout-body', [PARK_TOP, ...wrapLines, PARK_BOT], [
          { construct: wrapper, lineIndex: 1, colOffset: 0 },
          { construct, lineIndex: 2, colOffset: lead.length },
        ]);
        break;
      }
      case 'list-item': {
        if (lang === 'tex') {
          const lead = '\\item lead ';
          mk('list-item', [PARK_TOP, '\\begin{itemize}', `${lead}${T} tail`, '\\end{itemize}', PARK_BOT], [
            { construct: WRAPPERS.texList, lineIndex: 1, colOffset: 0 },
            { construct, lineIndex: 2, colOffset: lead.length },
          ]);
        } else {
          const lead = '- lead ';
          mk('list-item', [PARK_TOP, `${lead}${T} tail`, PARK_BOT], [
            { construct, lineIndex: 1, colOffset: lead.length },
          ]);
        }
        break;
      }
      case 'wrapped':
        mk('wrapped', [PARK_TOP, `${WRAP_LEAD}${T}${WRAP_TAIL}`, PARK_BOT], [
          { construct, lineIndex: 1, colOffset: WRAP_LEAD.length },
        ], { width: 40 });
        break;
      case 'above-display': {
        const lead = 'lead ';
        const block = lang === 'tex' ? ['\\[', 'q^2', '\\]'] : ['$$', 'q^2', '$$'];
        const blockConstruct = {
          name: 'display-neighbour',
          instances: [
            {
              kind: 'display-math',
              rule: lang === 'tex' ? 'R-T2' : 'R-M2',
              from: 0,
              to: block.join('\n').length,
              clickTarget: null,
            },
          ],
        };
        mk('above-display', [PARK_TOP, `${lead}${T} tail`, ...block, PARK_BOT], [
          { construct, lineIndex: 1, colOffset: lead.length },
          { construct: blockConstruct, lineIndex: 2, colOffset: 0 },
        ]);
        break;
      }
      default:
        throw new Error(`compose: inline construct ${construct.name} has unknown context ${context}`);
    }
  }
  return cells;
}

function composeBlock(construct) {
  const L = construct.lines;
  const lang = construct.language;
  const cells = [];
  const mk = (context, lines, placements, opts) =>
    cells.push(makeCell(construct, context, lines, placements, opts));

  // A GFM table swallows any directly following non-blank line as a lazy
  // continuation row (correct GFM), so table cells carry the blank line a
  // real document would have between the table and the next block.
  const pad = construct.name === 'table' ? [''] : [];

  for (const context of construct.contexts) {
    switch (context) {
      case 'plain':
        mk('plain', [PARK_TOP, ...L, ...pad, PARK_BOT], [{ construct, lineIndex: 1 }]);
        break;
      case 'plain-narrow':
        mk('plain-narrow', [PARK_TOP, ...L, PARK_BOT], [{ construct, lineIndex: 1 }], {
          viewport: 'narrow',
        });
        break;
      case 'wrapped-above':
        mk('wrapped-above', [WRAP_PARA, ...L, PARK_BOT], [{ construct, lineIndex: 1 }], {
          width: 40,
        });
        break;
      case 'absorb-callout': {
        const open = lang === 'tex' ? '\\begin{theorem}' : '::: {.callout-note}';
        const close = lang === 'tex' ? '\\end{theorem}' : ':::';
        const wrapper = wrapperWithClose(
          lang === 'tex' ? WRAPPERS.texCallout : WRAPPERS.mdCallout,
          2 + L.length,
        );
        mk('absorb-callout', [PARK_TOP, open, 'lead body line', ...L, close, ...pad, PARK_BOT], [
          { construct: wrapper, lineIndex: 1 },
          { construct, lineIndex: 3 },
        ]);
        break;
      }
      case 'absorb-list': {
        const wrapper = wrapperWithClose(WRAPPERS.texList, 2 + L.length, [
          { line: 1, from: 0, to: 6 },
        ]);
        mk('absorb-list', [PARK_TOP, '\\begin{itemize}', '\\item first thing', ...L, '\\end{itemize}', PARK_BOT], [
          { construct: wrapper, lineIndex: 1 },
          { construct, lineIndex: 3 },
        ]);
        break;
      }
      case 'absorb-nested-list': {
        // enumerate > itemize > math: the math widget absorbs BOTH close
        // fences (listFenceHideThrough walks consecutive fences).
        const outer = {
          name: 'enumerate-wrapper',
          instances: [
            {
              kind: 'list',
              rule: 'R-T7',
              openLine: 0,
              closeLine: 5 + L.length,
              openHasArgs: false,
              items: [{ line: 1, from: 0, to: 6 }],
              clickTarget: null,
            },
          ],
        };
        const inner = {
          name: 'itemize-wrapper',
          instances: [
            {
              kind: 'list',
              rule: 'R-T7',
              openLine: 2,
              closeLine: 4 + L.length,
              openHasArgs: false,
              items: [{ line: 3, from: 0, to: 6 }],
              clickTarget: null,
            },
          ],
        };
        mk(
          'absorb-nested-list',
          [
            PARK_TOP,
            '\\begin{enumerate}',
            '\\item one thing',
            '\\begin{itemize}',
            '\\item two thing',
            ...L,
            '\\end{itemize}',
            '\\end{enumerate}',
            PARK_BOT,
          ],
          [
            { construct: outer, lineIndex: 1 },
            { construct: inner, lineIndex: 1 },
            { construct, lineIndex: 5 },
          ],
        );
        break;
      }
      case 'callout-mid': {
        const wrapper = wrapperWithClose(WRAPPERS.mdCallout, 2 + L.length);
        mk('callout-mid', [PARK_TOP, '::: {.callout-note}', ...L, 'tail body line', ':::', PARK_BOT], [
          { construct: wrapper, lineIndex: 1 },
          { construct, lineIndex: 2 },
        ]);
        break;
      }
      case 'list-block': {
        // `$$…$$` indented as a list-item continuation: the block replace
        // must snap to the line start (blockReplaceFrom).
        if (L.length !== 1) throw new Error('list-block context expects a 1-line display');
        mk('list-block', [PARK_TOP, '- item lead text', `  ${L[0]}`, '- next item', PARK_BOT], [
          { construct, lineIndex: 2, colOffset: 2 },
        ]);
        break;
      }
      case 'beamer':
        mk('beamer', ['\\documentclass{beamer}', PARK_TOP, ...L, PARK_BOT], [
          { construct, lineIndex: 2 },
        ]);
        break;
      case 'tail':
        // No trailing park line and no trailing newline handling beyond the
        // composer's own: the unclosed $$ must reach EOF.
        cells.push({
          ...makeCell(construct, 'tail', [PARK_TOP, ...L], [{ construct, lineIndex: 1 }]),
        });
        break;
      default:
        throw new Error(`compose: block construct ${construct.name} has unknown context ${context}`);
    }
  }
  return cells;
}

/** The full matrix. */
export function composeCells() {
  const cells = [];
  for (const construct of CONSTRUCTS) {
    cells.push(...(construct.placement === 'inline' ? composeInline(construct) : composeBlock(construct)));
  }
  const ids = new Set();
  for (const c of cells) {
    if (ids.has(c.id)) throw new Error(`compose: duplicate cell id ${c.id}`);
    ids.add(c.id);
  }
  return cells;
}

/** The structural (jsdom) subset: one cell per distinct (language, doc) —
 *  width and viewport are geometry, which jsdom does not have. */
export function structuralCells() {
  const seen = new Set();
  return composeCells().filter((c) => {
    const key = `${c.language} ${c.doc}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
