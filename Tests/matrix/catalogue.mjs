/**
 * Construct catalogue for the discovery matrix.
 *
 * Every entry is a construct snippet plus STRUCTURAL metadata: where its
 * parts sit inside the snippet, how it reveals, and what its widget click
 * target is. The metadata is derived from the snippet strings the catalogue
 * itself owns (indexOf over its own literals), never from the engine — the
 * composer (compose.mjs) places snippets in contexts and shifts these
 * offsets to absolute document positions, so a cell knows its extents
 * without consulting a scanner.
 *
 * Instance kinds and the spec rows they encode
 * (docs/specs/2026-08-23-caret-and-reveal-semantics.md, section 2):
 *
 *   inline-math    R-T1 / R-M1   {from, to}
 *   display-math   R-T2 / R-M2   {from, to} (block; line-window)
 *   display-unclosed R-M2        {from, to} (predicts NO hides)
 *   command        R-T3          {cmdFrom, argFrom, argTo} (+ sectioning)
 *   pill           R-T4          {cmdFrom, argFrom, argTo} (whole-command)
 *   href           R-T5          {cmdFrom, textFrom, textTo}
 *   callout        R-T6 / R-M8   {openLine, closeLine} (0-based snippet lines)
 *   list           R-T7          {openLine, closeLine, items:[{from,to}]}
 *   frame          R-T8          {openLine, closeLine}
 *   whole-replace  R-T9 / R-M6   {from, to} (char-window whole replace)
 *   marker-pair    R-M4 / R-M5   {nodeFrom, nodeTo, hides:[{from,to},…]}
 *   heading-attr   R-M3          {nodeFrom, nodeTo, attrFrom}
 *   none           R-M7          {} (asserts nothing is ever hidden)
 *   table          R-M9          {fromLine, toLine} (block + atomic, no reveal)
 *
 * Offsets in `parts` are relative to the snippet: to the snippet string for
 * inline constructs, to the start of the snippet's first line for block
 * constructs. Line indexes are 0-based within the snippet's `lines`.
 */

/** Helper: offset of `needle` in `s`, throwing on a miss so a typo in a
 *  snippet cannot silently produce offset -1 metadata. */
function at(s, needle, from = 0) {
  const i = s.indexOf(needle, from);
  if (i === -1) throw new Error(`catalogue: ${JSON.stringify(needle)} not in ${JSON.stringify(s)}`);
  return i;
}

function inlineMath(language, text, contexts, sel) {
  return {
    name: text.startsWith('\\(') ? 'inline-paren' : 'inline-math',
    language,
    placement: 'inline',
    text,
    contexts,
    instances: [
      {
        kind: 'inline-math',
        rule: language === 'tex' ? 'R-T1' : 'R-M1',
        from: 0,
        to: text.length,
        clickTarget: sel ? { selector: sel, land: 0 } : null,
      },
    ],
  };
}

function texCommand(name, text, contexts) {
  const argFrom = at(text, '{') + 1;
  const argTo = at(text, '}', argFrom);
  return {
    name,
    language: 'tex',
    placement: 'inline',
    text,
    contexts,
    instances: [
      { kind: 'command', rule: 'R-T3', cmdFrom: 0, argFrom, argTo, clickTarget: null },
    ],
  };
}

function texPill(name, text, contexts, selector) {
  const argFrom = at(text, '{') + 1;
  const argTo = at(text, '}', argFrom);
  return {
    name,
    language: 'tex',
    placement: 'inline',
    text,
    contexts,
    instances: [
      {
        kind: 'pill',
        rule: 'R-T4',
        cmdFrom: 0,
        argFrom,
        argTo,
        clickTarget: selector ? { selector, land: argFrom } : null,
      },
    ],
  };
}

function markerPair(name, text, open, close, contexts) {
  const openFrom = 0;
  const closeFrom = text.length - close.length;
  return {
    name,
    language: 'md',
    placement: 'inline',
    text,
    contexts,
    instances: [
      {
        kind: 'marker-pair',
        rule: 'R-M4',
        nodeFrom: 0,
        nodeTo: text.length,
        hides: [
          { from: openFrom, to: openFrom + open.length },
          { from: closeFrom, to: closeFrom + close.length },
        ],
        clickTarget: null,
      },
    ],
  };
}

function displayMath(language, name, lines, contexts, sel) {
  const text = lines.join('\n');
  return {
    name,
    language,
    placement: 'block',
    lines,
    contexts,
    instances: [
      {
        kind: 'display-math',
        rule: language === 'tex' ? 'R-T2' : 'R-M2',
        from: 0,
        to: text.length,
        clickTarget: sel ? { selector: sel, land: 'replaceStart' } : null,
      },
    ],
  };
}

/** Callout snippet: instance line indexes are snippet-relative (0-based). */
function callout(language, name, lines, contexts) {
  return {
    name,
    language,
    placement: 'block',
    lines,
    contexts,
    instances: [
      {
        kind: 'callout',
        rule: language === 'tex' ? 'R-T6' : 'R-M8',
        openLine: 0,
        closeLine: lines.length - 1,
        clickTarget: null,
      },
    ],
  };
}

export const CONSTRUCTS = [
  // -------------------------------------------------------------- tex inline
  inlineMath(
    'tex',
    '$a+b$',
    ['start', 'mid', 'mid-w40', 'end', 'adjacent', 'callout-body', 'list-item', 'wrapped', 'above-display'],
    '.cm-tex-math-inline',
  ),
  inlineMath('tex', '\\(x_i\\)', ['mid'], '.cm-tex-math-inline'),
  texCommand('textbf', '\\textbf{bold}', ['start', 'mid', 'end', 'adjacent']),
  texCommand('emph', '\\emph{ital}', ['mid']),
  {
    // \textbf{\emph{xy}} — two independent command instances; the merged
    // prefix and the merged `}}` fall out of the shared merge step.
    name: 'nested-bf-em',
    language: 'tex',
    placement: 'inline',
    text: '\\textbf{\\emph{xy}}',
    contexts: ['mid'],
    instances: [
      { kind: 'command', rule: 'R-T3', cmdFrom: 0, argFrom: 8, argTo: 17, clickTarget: null },
      { kind: 'command', rule: 'R-T3', cmdFrom: 8, argFrom: 14, argTo: 16, clickTarget: null },
    ],
  },
  texPill('ref', '\\ref{fig:m}', ['mid', 'end', 'adjacent'], '.cm-tex-ref-pill'),
  texPill('cite', '\\cite{ab12,cd34}', ['mid'], '.cm-tex-ref-pill'),
  texPill('label', '\\label{eq:x}', ['mid'], '.cm-tex-label-pill'),
  texPill('footnote', '\\footnote{small note}', ['mid'], '.cm-tex-footnote-mark'),
  {
    name: 'href',
    language: 'tex',
    placement: 'inline',
    text: '\\href{https://x.y}{link text}',
    contexts: ['mid'],
    instances: [
      (() => {
        const t = '\\href{https://x.y}{link text}';
        const textFrom = at(t, '{link') + 1;
        return { kind: 'href', rule: 'R-T5', cmdFrom: 0, textFrom, textTo: t.length - 1, clickTarget: null };
      })(),
    ],
  },
  {
    name: 'includegraphics',
    language: 'tex',
    placement: 'inline',
    text: '\\includegraphics[width=0.5\\textwidth]{fig.png}',
    contexts: ['own-line'],
    instances: [
      {
        kind: 'whole-replace',
        rule: 'R-T9',
        from: 0,
        to: '\\includegraphics[width=0.5\\textwidth]{fig.png}'.length,
        clickTarget: null,
      },
    ],
  },
  texCommand('section', '\\section{Model}', ['own-line']),
  texCommand('subsection', '\\subsection{Households}', ['own-line']),

  // -------------------------------------------------------------- tex blocks
  displayMath('tex', 'display-1', ['\\[ e = mc^2 \\]'], ['plain', 'plain-narrow'], '.cm-tex-math-display'),
  displayMath(
    'tex',
    'display-3',
    ['\\[', 'E = mc^2', '\\]'],
    ['plain', 'plain-narrow', 'wrapped-above', 'absorb-callout'],
    '.cm-tex-math-display',
  ),
  displayMath(
    'tex',
    'equation',
    ['\\begin{equation}', 'E=mc^2', '\\end{equation}'],
    ['plain', 'absorb-list'],
    '.cm-tex-math-display',
  ),
  displayMath(
    'tex',
    'align',
    ['\\begin{align}', 'a &= b \\\\', 'c &= d', '\\end{align}'],
    ['plain'],
    '.cm-tex-math-display',
  ),
  callout('tex', 'theorem', ['\\begin{theorem}', 'body text here', '\\end{theorem}'], ['plain']),
  {
    name: 'itemize',
    language: 'tex',
    placement: 'block',
    lines: ['\\begin{itemize}', '\\item first thing', '\\item second thing', '\\end{itemize}'],
    contexts: ['plain'],
    instances: [
      {
        kind: 'list',
        rule: 'R-T7',
        openLine: 0,
        closeLine: 3,
        openHasArgs: false,
        // `\item ` token plus its trailing inline whitespace, per item line.
        items: [
          { line: 1, from: 0, to: 6 },
          { line: 2, from: 0, to: 6 },
        ],
        clickTarget: null,
      },
    ],
  },
  {
    // A frame needs the beamer documentclass header; the composer's `beamer`
    // context supplies it.
    name: 'frame',
    language: 'tex',
    placement: 'block',
    lines: ['\\begin{frame}{Title}{Sub}', 'first body line', 'second body line', '\\end{frame}'],
    contexts: ['beamer'],
    instances: [
      { kind: 'frame', rule: 'R-T8', openLine: 0, closeLine: 3, clickTarget: null },
    ],
  },

  // --------------------------------------------------------------- md inline
  inlineMath(
    'md',
    '$a+b$',
    ['start', 'mid', 'mid-w40', 'end', 'adjacent', 'callout-body', 'list-item', 'wrapped', 'above-display'],
    '.cm-math-inline',
  ),
  markerPair('bold', '**bold**', '**', '**', ['start', 'mid', 'end', 'adjacent']),
  markerPair('italic', '*ital*', '*', '*', ['mid']),
  markerPair('code', '`code`', '`', '`', ['mid']),
  markerPair('strike', '~~gone~~', '~~', '~~', ['mid']),
  markerPair('highlight', '==mark==', '==', '==', ['mid']),
  {
    name: 'link',
    language: 'md',
    placement: 'inline',
    text: '[link](https://x.y)',
    contexts: ['mid'],
    instances: [
      (() => {
        const t = '[link](https://x.y)';
        return {
          kind: 'marker-pair',
          rule: 'R-M5',
          nodeFrom: 0,
          nodeTo: t.length,
          hides: [
            { from: 0, to: 1 },
            { from: at(t, ']'), to: t.length },
          ],
          clickTarget: null,
        };
      })(),
    ],
  },
  {
    name: 'image',
    language: 'md',
    placement: 'inline',
    text: '![alt](img.png)',
    contexts: ['mid'],
    instances: [
      { kind: 'whole-replace', rule: 'R-M6', from: 0, to: '![alt](img.png)'.length, clickTarget: null },
    ],
  },
  {
    name: 'heading-plain',
    language: 'md',
    placement: 'inline',
    text: '# Heading one',
    contexts: ['own-line'],
    instances: [{ kind: 'none', rule: 'R-M3', clickTarget: null }],
  },
  {
    name: 'heading-attr',
    language: 'md',
    placement: 'inline',
    text: '# Setup {#sec-setup}',
    contexts: ['own-line'],
    instances: [
      (() => {
        const t = '# Setup {#sec-setup}';
        return {
          kind: 'heading-attr',
          rule: 'R-M3',
          nodeFrom: 0,
          nodeTo: t.length,
          attrFrom: at(t, ' {#'),
          clickTarget: null,
        };
      })(),
    ],
  },
  {
    name: 'blockquote',
    language: 'md',
    placement: 'inline',
    text: '> quoted line here',
    contexts: ['own-line'],
    instances: [{ kind: 'none', rule: 'R-M7', clickTarget: null }],
  },

  // --------------------------------------------------------------- md blocks
  displayMath('md', 'display-1', ['$$x^2 + y^2$$'], ['plain', 'list-block'], '.cm-math-display'),
  displayMath(
    'md',
    'display-3',
    ['$$', 'E = mc^2', '$$'],
    ['plain', 'plain-narrow', 'absorb-callout', 'callout-mid', 'wrapped-above'],
    '.cm-math-display',
  ),
  {
    // Unclosed $$: renders NOTHING (no hides, no widget). Must sit at the
    // document tail so nothing below it could close the block.
    name: 'display-unclosed',
    language: 'md',
    placement: 'block',
    lines: ['$$', 'x^2 unfinished'],
    contexts: ['tail'],
    instances: [
      { kind: 'display-unclosed', rule: 'R-M2', from: 0, to: '$$\nx^2 unfinished'.length, clickTarget: null },
    ],
  },
  callout('md', 'callout-note', ['::: {.callout-note}', 'note body here', ':::'], ['plain']),
  callout('md', 'callout-thm', ['::: {#thm-pyth name="Pyth"}', 'theorem body here', ':::'], ['plain']),
  {
    name: 'table',
    language: 'md',
    placement: 'block',
    lines: ['| a | b |', '| --- | --- |', '| 1 | 2 |'],
    contexts: ['plain', 'absorb-callout'],
    instances: [
      { kind: 'table', rule: 'R-M9', fromLine: 0, toLine: 2, clickTarget: null },
    ],
  },
];

/** Sanity: every snippet is ASCII, so predictHorizontal's one-position
 *  grapheme model is exact (the multi-byte grapheme cases are owned by
 *  Tests/fixtures/caret/19,20,27,28). Throws at import time on violation. */
for (const c of CONSTRUCTS) {
  const body = c.placement === 'inline' ? c.text : c.lines.join('\n');
  // eslint-disable-next-line no-control-regex
  if (!/^[\x00-\x7F]*$/.test(body)) throw new Error(`catalogue: non-ASCII snippet in ${c.name}`);
}
