import type { Text } from '@codemirror/state';
import { texLines, uncommented } from './tex-lines';

/**
 * The standalone LaTeX document a TikZ widget asks the host to typeset, and
 * where the pictures are. Pure: no DOM, no view. The host only compiles what
 * it is given, so every host draws the same figure from the same source.
 */

/**
 * Preamble commands a figure can depend on. Everything else (beamer themes,
 * `\title`, `\hypersetup`, font setup, `\tikzexternalize`) is dropped: under
 * `standalone` it errors or only costs time.
 */
const KEPT_COMMANDS = new Set([
  'usepackage',
  'RequirePackage',
  'usetikzlibrary',
  'usepgfplotslibrary',
  'usepgflibrary',
  'pgfplotsset',
  'tikzset',
  'tikzstyle',
  'tikzcdset',
  'definecolor',
  'colorlet',
  'newcommand',
  'renewcommand',
  'providecommand',
  'DeclareMathOperator',
  'DeclareRobustCommand',
  'DeclarePairedDelimiter',
  'def',
  'gdef',
  'let',
  'newif',
  'newlength',
  'setlength',
  'pgfmathsetmacro',
  'pgfdeclarelayer',
  'pgfsetlayers',
  'input',
  'makeatletter',
  'makeatother',
]);

/** Packages that fail under pdflatex + standalone, need a shell escape, or
 *  only shape the page around the figure. */
const DROPPED_PACKAGES = new Set([
  'fontspec',
  'unicode-math',
  'polyglossia',
  'luacode',
  'luatexja',
  'xeCJK',
  'minted',
  'pythontex',
  'hyperref',
  'cleveref',
  'bookmark',
  'geometry',
  'biblatex',
  'natbib',
  'fancyhdr',
  'titlesec',
  'subfiles',
  'xr',
  'xr-hyper',
]);

/** Used when the document has no preamble of its own (Markdown, a chapter). */
const DEFAULT_PREAMBLE = '\\usepackage{amsmath,amssymb}';

const BEGIN_DOCUMENT = /\\begin\s*\{document\}/;
const PICTURE = /\\(begin|end)\s*\{(tikzpicture|tikzcd)\}/g;

export interface TikzPreamble {
  /** The kept preamble statements, one per line. */
  preamble: string;
  /** Font size options (`11pt`) carried over from `\documentclass`. */
  classOptions: string[];
}

/** Unescaped `{` minus `}` in `text`. */
function braceDelta(text: string): number {
  let delta = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '\\') i++;
    else if (c === '{') delta++;
    else if (c === '}') delta--;
  }
  return delta;
}

/** Comment-free statements: a line at brace depth 0 starts one, and lines
 *  continue it while its braces are open (a multi-line `\tikzset{…}`). */
function statements(text: string): string[] {
  const out: string[] = [];
  let current = '';
  let depth = 0;
  for (const raw of text.split('\n')) {
    const line = uncommented(raw);
    if (depth === 0) {
      if (current.trim()) out.push(current);
      current = line;
    } else {
      current += '\n' + line;
    }
    depth = Math.max(0, depth + braceDelta(line));
  }
  if (current.trim()) out.push(current);
  return out;
}

function commandName(statement: string): string | null {
  const m = /^\s*\\([A-Za-z@]+)/.exec(statement);
  return m ? m[1] : null;
}

/** `statement` with dropped packages taken out of every `\usepackage{a,b}`. */
function withoutDroppedPackages(statement: string): string {
  return statement.replace(
    /\\(usepackage|RequirePackage)\s*(\[[^\]]*\])?\s*\{([^}]*)\}/g,
    (_all, cmd: string, opts: string | undefined, list: string) => {
      const kept = list
        .split(',')
        .map((p) => p.trim())
        .filter((p) => p && !DROPPED_PACKAGES.has(p));
      return kept.length ? `\\${cmd}${opts ?? ''}{${kept.join(',')}}` : '';
    },
  );
}

/** The figure-relevant part of a preamble (or of a fence's head). */
export function keepPreamble(head: string): string {
  return statements(head)
    .filter((s) => {
      const name = commandName(s);
      return name !== null && KEPT_COMMANDS.has(name);
    })
    .map(withoutDroppedPackages)
    .filter((s) => s.trim())
    .join('\n');
}

/** A tex preamble (the text before `\begin{document}`), filtered. */
export function texPreamble(head: string): TikzPreamble {
  const cls = /\\documentclass\s*\[([^\]]*)\]/.exec(head);
  const classOptions = cls
    ? cls[1]
        .split(',')
        .map((o) => o.trim())
        .filter((o) => /^\d+pt$/.test(o))
    : [];
  return { preamble: keepPreamble(head), classOptions };
}

/** Packages a fence body needs that a bare tikz preamble lacks. */
function impliedPackages(body: string, head: string): string[] {
  const out: string[] = [];
  if (/\\begin\s*\{tikzcd\}/.test(body) && !/tikz-cd/.test(head)) out.push('\\usepackage{tikz-cd}');
  if (/\\begin\s*\{\w*axis\}/.test(body) && !/pgfplots/.test(head)) {
    out.push('\\usepackage{pgfplots}', '\\pgfplotsset{compat=newest}');
  }
  return out;
}

/**
 * The document for a ```` ```tikz ```` fence. The body may be a whole
 * document (`\usepackage…` then `\begin{document}…`, the TikZJax spelling),
 * preamble lines then a picture, or bare drawing commands, which get wrapped
 * in a `tikzpicture`. Quarto chunk options (`#| …`) are skipped.
 */
export function fenceTikzDocument(fenceBody: string): string {
  const text = fenceBody
    .split('\n')
    .filter((l) => !/^\s*#\|/.test(l))
    .join('\n');
  let head = '';
  let body: string;
  const doc = BEGIN_DOCUMENT.exec(text);
  const env = /\\begin\s*\{(tikzpicture|tikzcd)\}/.exec(text);
  if (doc) {
    head = text.slice(0, doc.index);
    const end = text.indexOf('\\end{document}');
    body = text.slice(doc.index + doc[0].length, end === -1 ? undefined : end).trim();
  } else if (env) {
    head = text.slice(0, env.index);
    body = text.slice(env.index).trim();
  } else {
    // Leading package lines are preamble; the rest is the picture.
    const lines = text.split('\n');
    let split = 0;
    while (split < lines.length && /^\s*(\\use(package|tikzlibrary|pgfplotslibrary)\b|$)/.test(lines[split])) split++;
    head = lines.slice(0, split).join('\n');
    body = `\\begin{tikzpicture}\n${lines.slice(split).join('\n').trim()}\n\\end{tikzpicture}`;
  }
  const kept = keepPreamble(head);
  const preamble = [DEFAULT_PREAMBLE, kept, ...impliedPackages(body, kept)].filter(Boolean).join('\n');
  return tikzDocument(body, { preamble, classOptions: [] });
}

/** A preamble line that already loads tikz, itself or through a package built on it. */
const LOADS_TIKZ = /\\(usepackage|RequirePackage)\s*(\[[^\]]*\])?\s*\{[^}]*\b(tikz|tikz-cd|pgfplots|circuitikz)\b/;

/**
 * Wrap `body` in a cropped `standalone` page. Without a preamble the default
 * math packages stand in. tikz is loaded first, before any `\usetikzlibrary`,
 * unless the preamble loads it: a second, option-less `\usepackage{tikz}`
 * ahead of the user's `\usepackage[opts]{tikz}` would be an option clash.
 */
export function tikzDocument(body: string, preamble: TikzPreamble | null): string {
  const options = ['border=2pt', ...(preamble?.classOptions ?? [])];
  const lines = preamble ? preamble.preamble : DEFAULT_PREAMBLE;
  return [
    `\\documentclass[${options.join(',')}]{standalone}`,
    LOADS_TIKZ.test(lines) ? '' : '\\usepackage{tikz}',
    lines,
    '\\begin{document}',
    body,
    '\\end{document}',
    '',
  ]
    .filter((line, i) => (i !== 1 && i !== 2) || line)
    .join('\n');
}

/**
 * TeX's `l.N` context names a line of the generated document. Rewrite it as
 * the user's line when the picture's first line is known (`firstLine`, the
 * line of `\begin{…}` in a .tex file); otherwise (a fence body that may have
 * been wrapped) drop the number and keep the context.
 */
export function localizeError(error: string, document: string, firstLine: number | null): string {
  const at = document.indexOf('\n\\begin{document}\n');
  const bodyLine = at === -1 ? null : document.slice(0, at).split('\n').length + 2;
  return error.replace(/^l\.(\d+)\s*/m, (_all, n: string) =>
    firstLine !== null && bodyLine !== null ? `line ${Number(n) - bodyLine + firstLine}: ` : '',
  );
}

export interface TexPicture {
  /** Offset of `\begin{…}`. */
  from: number;
  /** Offset just past the matching `\end{…}`. */
  to: number;
  /** 1-based line of the `\end{…}`: the widget goes under it. */
  endLine: number;
}

export interface TexPictures {
  pictures: TexPicture[];
  /** Offset of `\begin{document}`, or -1 in a file without one (a chapter
   *  that a root file `\input`s, which has no preamble of its own). */
  bodyStart: number;
}

/**
 * Top-level `tikzpicture` / `tikzcd` environments, in order. A preamble macro
 * that holds one is not a picture, so pictures before `\begin{document}` are
 * dropped. An unclosed picture is skipped.
 */
export function scanTexPictures(doc: Text): TexPictures {
  const found: TexPicture[] = [];
  let bodyStart = -1;
  let depth = 0;
  let from = 0;
  for (const { line, verbatim } of texLines(doc)) {
    if (verbatim) continue;
    const text = uncommented(line.text);
    if (bodyStart === -1) {
      const m = BEGIN_DOCUMENT.exec(text);
      if (m) bodyStart = line.from + m.index;
    }
    if (!text.includes('tikz')) continue;
    PICTURE.lastIndex = 0;
    for (let m = PICTURE.exec(text); m; m = PICTURE.exec(text)) {
      if (m[1] === 'begin') {
        if (depth === 0) from = line.from + m.index;
        depth++;
      } else if (depth > 0) {
        depth--;
        if (depth === 0) found.push({ from, to: line.from + m.index + m[0].length, endLine: line.number });
      }
    }
  }
  return { pictures: found.filter((p) => p.from > bodyStart), bodyStart };
}
