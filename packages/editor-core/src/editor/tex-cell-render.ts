// Display rendering of one tabular cell's source: math through KaTeX, a small
// set of text macros as DOM, everything else as its own source text. Built
// from DOM nodes (never an HTML string of user text); only KaTeX's own output
// goes through innerHTML. An unknown command shows verbatim so nothing in a
// cell is silently hidden.

import type { KaTeXCache } from '../utils/katex-cache';
import { scanMathRegions } from './tex-math-incremental';
import { stripComments } from './tex-table-model';

type Wrap = 'b' | 'i' | 'u' | 'code' | 'sc' | 'sup' | 'sub' | null;

/** One-argument commands rendered as their argument, wrapped. */
const WRAPPERS: Record<string, Wrap> = {
  textbf: 'b',
  textit: 'i',
  textsl: 'i',
  emph: 'i',
  underline: 'u',
  texttt: 'code',
  textsc: 'sc',
  textsuperscript: 'sup',
  textsubscript: 'sub',
  tnote: 'sup',
  textrm: null,
  textsf: null,
  textup: null,
  textnormal: null,
  text: null,
  mbox: null,
  hbox: null,
  fbox: null,
  makecell: null,
  shortstack: null,
  thead: null,
  mc: null,
  mr: null,
};

/** Declarations that restyle the rest of their group. */
const DECLARATIONS: Record<string, Wrap> = {
  bfseries: 'b',
  bf: 'b',
  itshape: 'i',
  it: 'i',
  em: 'i',
  slshape: 'i',
  ttfamily: 'code',
  tt: 'code',
  scshape: 'sc',
};

/** Commands that draw nothing in a cell; their arguments are dropped. */
const SILENT: Record<string, number> = {
  label: 1,
  hspace: 1,
  vspace: 1,
  phantom: 1,
  hphantom: 1,
  vphantom: 1,
  rowcolor: 1,
  cellcolor: 1,
  color: 1,
  rule: 2,
  centering: 0,
  raggedright: 0,
  raggedleft: 0,
  arraybackslash: 0,
  normalsize: 0,
  small: 0,
  footnotesize: 0,
  scriptsize: 0,
  tiny: 0,
  large: 0,
  Large: 0,
  LARGE: 0,
  huge: 0,
  Huge: 0,
  normalfont: 0,
  rmfamily: 0,
  sffamily: 0,
  upshape: 0,
  mdseries: 0,
  strut: 0,
  hfill: 0,
  null: 0,
  noindent: 0,
  relax: 0,
};

const SYMBOLS: Record<string, string> = {
  ldots: '…',
  dots: '…',
  textellipsis: '…',
  textendash: '\u2013',
  textemdash: '\u2014',
  textbackslash: '\\',
  textdagger: '†',
  dag: '†',
  textdaggerdbl: '‡',
  ddag: '‡',
  S: '§',
  P: '¶',
  checkmark: '✓',
  textasciitilde: '~',
  textasciicircum: '^',
  textbar: '|',
  textless: '<',
  textgreater: '>',
  textbullet: '•',
  textdegree: '°',
  textperthousand: '‰',
  copyright: '©',
  texttimes: '×',
  textpm: '±',
  euro: '€',
  pounds: '£',
  LaTeX: 'LaTeX',
  TeX: 'TeX',
  quad: '\u2003',
  qquad: '\u2003\u2003',
  enspace: '\u2002',
};

const ESCAPED: Record<string, string> = {
  '%': '%',
  '&': '&',
  $: '$',
  '#': '#',
  _: '_',
  '{': '{',
  '}': '}',
  ' ': ' ',
  ',': '\u2009',
  ';': '\u2005',
  ':': '\u2005',
  '!': '',
  '-': '',
  '/': '',
  '@': '',
};

const REFS = new Set(['ref', 'eqref', 'autoref', 'cref', 'Cref', 'pageref']);
const CITES = /^(?:cite|citet|citep|citealt|citealp|citeauthor|citeyear|parencite|textcite|autocite)$/;

function wrapEl(kind: Wrap): HTMLElement {
  if (kind === 'sc') {
    const s = document.createElement('span');
    s.className = 'cm-tex-cell-sc';
    return s;
  }
  if (kind === null) return document.createElement('span');
  return document.createElement(kind);
}

/** Index after the `{…}` / `[…]` group at `i`, or -1. */
function groupEnd(s: string, i: number): number {
  const open = s[i];
  const close = open === '{' ? '}' : open === '[' ? ']' : '';
  if (!close) return -1;
  let depth = 0;
  for (let j = i; j < s.length; j++) {
    if (s[j] === '\\') {
      j++;
      continue;
    }
    if (s[j] === open) depth++;
    else if (s[j] === close && --depth === 0) return j + 1;
  }
  return -1;
}

function skipWs(s: string, i: number): number {
  while (i < s.length && /\s/.test(s[i])) i++;
  return i;
}

/** Text with TeX ligatures and quotes typeset. */
function typeset(text: string): string {
  // Collapse source whitespace first: `\s` would also eat the nbsp from `~`.
  return text
    .replace(/[ \t\r\n]+/g, ' ')
    .replace(/---/g, '\u2014')
    .replace(/--/g, '\u2013')
    .replace(/``/g, '\u201c')
    .replace(/''/g, '\u201d')
    .replace(/`/g, '\u2018')
    .replace(/~/g, '\u00a0');
}

class CellRenderer {
  constructor(private readonly cache: KaTeXCache) {}

  /** Render `src` (comment-free) into `parent`. */
  render(src: string, parent: HTMLElement): void {
    this.text(src, parent);
  }

  private math(content: string, display: boolean, raw: string, parent: HTMLElement): void {
    const span = document.createElement('span');
    // Inline even for `$$` / `\[`: a cell is a line of text.
    const html = this.cache.render(display ? `\\displaystyle ${content}` : content, false);
    if (html === null) {
      span.className = 'cm-tex-cell-error';
      span.textContent = raw;
    } else {
      span.className = 'cm-tex-cell-math';
      span.innerHTML = html;
    }
    parent.appendChild(span);
  }

  /** Source into `parent`. Math is picked up where it opens, so
   *  `\textbf{$x$}` keeps its group. */
  private text(s: string, parent: HTMLElement): void {
    let target = parent;
    let buf = '';
    const flush = (): void => {
      if (buf) target.appendChild(document.createTextNode(typeset(buf)));
      buf = '';
    };
    let i = 0;
    while (i < s.length) {
      const ch = s[i];
      if (ch === '$' || (ch === '\\' && (s[i + 1] === '(' || s[i + 1] === '['))) {
        const m = scanMathRegions(s.slice(i))[0];
        if (m && m.from === 0) {
          flush();
          this.math(m.content, m.display, s.slice(i, i + m.to), target);
          i += m.to;
          continue;
        }
      }
      if (ch === '{') {
        const end = groupEnd(s, i);
        if (end === -1) {
          buf += ch;
          i++;
          continue;
        }
        flush();
        const group = document.createElement('span');
        this.render(s.slice(i + 1, end - 1), group);
        target.appendChild(group);
        i = end;
        continue;
      }
      if (ch === '}') {
        i++;
        continue;
      }
      if (ch !== '\\') {
        buf += ch;
        i++;
        continue;
      }
      const next = s[i + 1];
      if (next === undefined) {
        buf += ch;
        i++;
        continue;
      }
      if (next === '\\' || s.startsWith('newline', i + 1)) {
        // `\\` inside `\makecell{…}` is a line break.
        flush();
        target.appendChild(document.createElement('br'));
        i += next === '\\' ? 2 : '\\newline'.length;
        const g = skipWs(s, i);
        if (s[g] === '[') i = Math.max(i, groupEnd(s, g));
        continue;
      }
      if (next in ESCAPED) {
        buf += ESCAPED[next];
        i += 2;
        continue;
      }
      let j = i + 1;
      while (j < s.length && /[A-Za-z@]/.test(s[j])) j++;
      if (j === i + 1) {
        buf += s.slice(i, i + 2);
        i += 2;
        continue;
      }
      const name = s.slice(i + 1, j);
      // A control word eats the spaces after it.
      const afterName = skipWs(s, j);

      if (name in SYMBOLS) {
        buf += SYMBOLS[name];
        i = afterName;
        continue;
      }
      if (name in DECLARATIONS) {
        flush();
        const el = wrapEl(DECLARATIONS[name]);
        target.appendChild(el);
        target = el;
        i = afterName;
        continue;
      }
      if (name in SILENT) {
        let k = afterName;
        if (s[k] === '[') k = Math.max(k, groupEnd(s, k));
        for (let a = 0; a < SILENT[name]; a++) {
          const g = skipWs(s, k);
          if (s[g] !== '{') break;
          const e = groupEnd(s, g);
          if (e === -1) break;
          k = e;
        }
        i = SILENT[name] === 0 ? afterName : k;
        continue;
      }
      if (name === 'textcolor' || name === 'colorbox' || name === 'href') {
        // Drop the first argument, render the second.
        const g = afterName;
        const e = s[g] === '{' ? groupEnd(s, g) : -1;
        if (e !== -1) {
          i = e;
          continue;
        }
      }
      if (name in WRAPPERS) {
        let g = afterName;
        // `\makecell[l]{…}`, `\thead[c]{…}`
        if (s[g] === '[') g = skipWs(s, Math.max(g, groupEnd(s, g)));
        const e = s[g] === '{' ? groupEnd(s, g) : -1;
        if (e !== -1) {
          flush();
          const el = wrapEl(WRAPPERS[name]);
          this.render(s.slice(g + 1, e - 1), el);
          target.appendChild(el);
          i = e;
          continue;
        }
      }
      if (REFS.has(name) || CITES.test(name)) {
        let g = afterName;
        while (s[g] === '[') g = skipWs(s, Math.max(g + 1, groupEnd(s, g)));
        const e = s[g] === '{' ? groupEnd(s, g) : -1;
        if (e !== -1) {
          flush();
          const chip = document.createElement('span');
          chip.className = 'cm-tex-cell-ref';
          const key = s.slice(g + 1, e - 1);
          chip.textContent = REFS.has(name) ? key : `[${key}]`;
          target.appendChild(chip);
          i = e;
          continue;
        }
      }
      if (name === 'footnote') {
        const g = afterName;
        const e = s[g] === '{' ? groupEnd(s, g) : -1;
        if (e !== -1) {
          flush();
          const sup = document.createElement('sup');
          sup.textContent = '*';
          sup.title = s.slice(g + 1, e - 1);
          target.appendChild(sup);
          i = e;
          continue;
        }
      }
      // Unknown: the command as written; its groups render as content.
      flush();
      const raw = document.createElement('span');
      raw.className = 'cm-tex-cell-cmd';
      raw.textContent = s.slice(i, j);
      target.appendChild(raw);
      i = j;
    }
    flush();
  }
}

/** Render a cell's source into `el`, replacing its children. */
export function renderTexCell(src: string, el: HTMLElement, cache: KaTeXCache): void {
  el.textContent = '';
  new CellRenderer(cache).render(stripComments(src).trim(), el);
}
