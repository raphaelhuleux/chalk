// Pure model of LaTeX tabular-family environments (no DOM, no CodeMirror
// view). Lossless by construction: every cell, rule and spec column keeps its
// document range, and every edit is a set of changes to those ranges, so the
// source around them (spacing, comments, `\resizebox` wrappers) is never
// reformatted. This is the opposite of the GFM model (table-model.ts), which
// re-serializes the whole table: a tex user's layout is theirs.

import type { Text } from '@codemirror/state';
import { memoByDoc } from '../utils/memo-by-doc';
import { docText } from '../utils/doc-text';

export type TexAlign = 'left' | 'center' | 'right';

/** One document change, in absolute offsets. */
export interface TexChange {
  from: number;
  to: number;
  insert: string;
}

/** A horizontal rule above a row (or below the last), over logical columns
 *  `from..to` inclusive. */
export interface TexRule {
  weight: 'thin' | 'heavy';
  from: number;
  to: number;
}

export interface SpecColumn {
  align: TexAlign;
  /** Range of a plain `l`/`c`/`r` letter, the only alignment we rewrite. */
  letter: { from: number; to: number } | null;
  /** Whole token, `>{…}` and `<{…}` included. Offsets are relative to the
   *  spec text in `parseColumnSpec`, absolute in `TexTable.columns`. */
  from: number;
  to: number;
}

export interface ColumnSpec {
  columns: SpecColumn[];
  /** Vertical rule count at each boundary: index k is left of column k. */
  vrules: number[];
  /** Ranges of the `|` runs, by boundary, for deletion. */
  vruleRanges: Array<{ from: number; to: number } | null>;
}

export interface TexCell {
  /** The cell's whole segment between delimiters, whitespace included. */
  segFrom: number;
  segTo: number;
  /** Trimmed source of the whole cell. */
  from: number;
  to: number;
  /** What the user edits: the content argument of `\multicolumn` /
   *  `\multirow`, else the trimmed cell. */
  editFrom: number;
  editTo: number;
  span: number;
  /** Range of the `\multicolumn` count digits, to widen or narrow a span. */
  spanArg: { from: number; to: number } | null;
  /** Logical start column. */
  col: number;
  /** `\multicolumn` alignment override. */
  align: TexAlign | null;
  multirow: boolean;
  /** Position of the `&` after this cell, or -1 for the last cell. */
  ampAfter: number;
}

export interface TexRow {
  /** Segment start: just after the previous row's terminator. */
  from: number;
  /** After the leading rule commands; cell 0 starts here. */
  contentFrom: number;
  rules: TexRule[];
  /** Source range of the leading rule commands, null when there are none. */
  rulesRange: { from: number; to: number } | null;
  cells: TexCell[];
  /** `\\[len]` / `\tabularnewline`; `endFrom === endTo` when absent. */
  endFrom: number;
  endTo: number;
}

export interface TexTable {
  env: string;
  /** `\begin` and one past `\end{env}`. */
  from: number;
  to: number;
  /** Inside the spec braces. */
  specFrom: number;
  specTo: number;
  spec: ColumnSpec;
  rows: TexRow[];
  /** Rules after the last row (`\bottomrule`). */
  trailingRules: TexRule[];
  trailingRulesRange: { from: number; to: number } | null;
  /** Logical column count: the spec's, or the widest row when wider. */
  ncols: number;
  /** tblr `hlines` / `vlines` keys: rules everywhere. */
  allHLines: boolean;
  allVLines: boolean;
}

/** Braced arguments before the body; the spec is the last one. */
const TABLE_ENVS: Record<string, number> = {
  tabular: 1,
  'tabular*': 2,
  tabularx: 2,
  tabulary: 2,
  longtable: 1,
  'longtable*': 1,
  tblr: 1,
  longtblr: 1,
  talltblr: 1,
};

const BEGIN_TABLE = /\\begin\{(tabular\*?|tabular[xy]|longtable\*?|tblr|longtblr|talltblr)\}/g;
const VERBATIM_ENV = /\\begin\{(verbatim\*?|lstlisting|minted)\}[\s\S]*?\\end\{\1\}/g;

// ---- Low-level scanning ----

function isSpace(ch: string | undefined): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';
}

function isLetter(ch: string | undefined): boolean {
  return ch !== undefined && /[A-Za-z@]/.test(ch);
}

/** Index after the group opened by `open` at `i`, or -1 if unclosed. Honors
 *  `\x` escapes; `[…]` groups nest braces so `[{a]b}]` stays one group. */
function skipGroup(text: string, i: number, end = text.length): number {
  const open = text[i];
  const close = open === '{' ? '}' : open === '[' ? ']' : open === '(' ? ')' : '';
  if (!close) return -1;
  let depth = 0;
  for (let j = i; j < end; j++) {
    const ch = text[j];
    if (ch === '\\') {
      j++;
      continue;
    }
    if (ch === '%') {
      while (j < end && text[j] !== '\n') j++;
      continue;
    }
    if (open !== '{' && ch === '{') {
      const k = skipGroup(text, j, end);
      if (k === -1) return -1;
      j = k - 1;
      continue;
    }
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return j + 1;
    }
  }
  return -1;
}

function skipSpace(text: string, i: number, end = text.length): number {
  while (i < end && isSpace(text[i])) i++;
  return i;
}

/** Skip whitespace and `%` comments. */
function skipSpaceAndComments(text: string, i: number, end = text.length): number {
  for (;;) {
    i = skipSpace(text, i, end);
    if (i < end && text[i] === '%') {
      while (i < end && text[i] !== '\n') i++;
      continue;
    }
    return i;
  }
}

/** `\name` at `i`: the name and the index after it. */
function readCommand(text: string, i: number): { name: string; end: number } | null {
  if (text[i] !== '\\') return null;
  let j = i + 1;
  while (j < text.length && isLetter(text[j])) j++;
  if (j === i + 1) return null;
  return { name: text.slice(i + 1, j), end: j };
}

/** Whether `pos` sits in a `%` comment on its line. */
function inComment(text: string, pos: number): boolean {
  let i = text.lastIndexOf('\n', pos - 1) + 1;
  for (; i < pos; i++) {
    if (text[i] === '\\') {
      i++;
      continue;
    }
    if (text[i] === '%') return true;
  }
  return false;
}

/** Whether `text` has an unescaped `%`. */
export function hasComment(text: string): boolean {
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\\') {
      i++;
      continue;
    }
    if (text[i] === '%') return true;
  }
  return false;
}

/** `text` with `%` comments removed (the newline stays). */
export function stripComments(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === '\\' && i + 1 < text.length) {
      out += ch + text[i + 1];
      i++;
      continue;
    }
    if (ch === '%') {
      while (i < text.length && text[i] !== '\n') i++;
      if (i < text.length) out += '\n';
      continue;
    }
    out += ch;
  }
  return out;
}

// ---- Column spec ----

function alignFromLetter(ch: string): TexAlign {
  if (ch === 'c' || ch === 'C') return 'center';
  if (ch === 'r' || ch === 'R') return 'right';
  return 'left';
}

/** `>{\centering\arraybackslash}` and friends override a paragraph column. */
function alignFromPre(pre: string): TexAlign | null {
  if (/\\centering\b/.test(pre)) return 'center';
  if (/\\raggedleft\b/.test(pre)) return 'right';
  if (/\\raggedright\b/.test(pre)) return 'left';
  return null;
}

/** Expand every `*{n}{sub}` in a spec, recursively. */
export function expandSpecRepeats(spec: string): string {
  let out = '';
  for (let i = 0; i < spec.length; i++) {
    const ch = spec[i];
    if (ch === '*' && spec[i + 1] === '{') {
      const nEnd = skipGroup(spec, i + 1);
      if (nEnd !== -1 && spec[nEnd] === '{') {
        const subEnd = skipGroup(spec, nEnd);
        const n = parseInt(spec.slice(i + 2, nEnd - 1).trim(), 10);
        if (subEnd !== -1 && Number.isFinite(n) && n >= 0 && n < 100) {
          out += expandSpecRepeats(spec.slice(nEnd + 1, subEnd - 1)).repeat(n);
          i = subEnd - 1;
          continue;
        }
      }
    }
    out += ch;
  }
  return out;
}

/**
 * Columns of a tabular preamble. Offsets are relative to `spec`, which must
 * already be repeat-expanded for them to mean anything (`*{n}{…}` groups are
 * expanded first by the caller when it needs ranges). Unknown letters (a
 * `\newcolumntype`) count as left-aligned columns.
 */
export function parseColumnSpec(spec: string): ColumnSpec {
  const columns: SpecColumn[] = [];
  const vrules: number[] = [0];
  const vruleRanges: Array<{ from: number; to: number } | null> = [null];
  let pendingFrom = -1;
  let pendingAlign: TexAlign | null = null;

  const push = (col: SpecColumn): void => {
    columns.push(col);
    vrules.push(0);
    vruleRanges.push(null);
    pendingFrom = -1;
    pendingAlign = null;
  };

  let i = 0;
  while (i < spec.length) {
    const ch = spec[i];
    if (isSpace(ch)) {
      i++;
      continue;
    }
    if (ch === '%') {
      while (i < spec.length && spec[i] !== '\n') i++;
      continue;
    }
    if (ch === '|' || ch === ':') {
      const k = columns.length;
      vrules[k]++;
      const r = vruleRanges[k];
      vruleRanges[k] = r ? { from: r.from, to: i + 1 } : { from: i, to: i + 1 };
      i++;
      continue;
    }
    if (ch === '@' || ch === '!') {
      const j = skipGroup(spec, skipSpace(spec, i + 1));
      i = j === -1 ? spec.length : j;
      continue;
    }
    if (ch === '>') {
      const g = skipSpace(spec, i + 1);
      const j = skipGroup(spec, g);
      if (pendingFrom === -1) pendingFrom = i;
      if (j !== -1) pendingAlign = alignFromPre(spec.slice(g, j)) ?? pendingAlign;
      i = j === -1 ? spec.length : j;
      continue;
    }
    if (ch === '<') {
      const j = skipGroup(spec, skipSpace(spec, i + 1));
      const last = columns[columns.length - 1];
      if (last && j !== -1) last.to = j;
      i = j === -1 ? spec.length : j;
      continue;
    }
    if (ch === '*') {
      // Unexpanded repeat: count its columns, no usable ranges.
      const nEnd = skipGroup(spec, i + 1);
      const subEnd = nEnd === -1 ? -1 : skipGroup(spec, nEnd);
      if (subEnd === -1) {
        i = spec.length;
        continue;
      }
      const inner = parseColumnSpec(expandSpecRepeats(spec.slice(i, subEnd)));
      for (const c of inner.columns) {
        push({ align: c.align, letter: null, from: i, to: subEnd });
      }
      i = subEnd;
      continue;
    }
    if (isLetter(ch)) {
      const from = pendingFrom === -1 ? i : pendingFrom;
      let end = i + 1;
      let align: TexAlign = 'left';
      let letter: { from: number; to: number } | null = null;
      if ('lcr'.includes(ch)) {
        align = alignFromLetter(ch);
        letter = { from: i, to: i + 1 };
      } else if ('pmb'.includes(ch)) {
        const j = skipGroup(spec, skipSpace(spec, end));
        if (j !== -1) end = j;
      } else if (ch === 'D') {
        // dcolumn: D{sep}{outsep}{places}
        for (let k = 0; k < 3; k++) {
          const j = skipGroup(spec, skipSpace(spec, end));
          if (j === -1) break;
          end = j;
        }
        align = 'center';
      } else {
        // X / Q / S / tabulary L C R J, each with an optional `[…]`.
        if ('LCRJ'.includes(ch)) align = alignFromLetter(ch);
        if (ch === 'S' || ch === 's') align = 'center';
        const g = skipSpace(spec, end);
        if (spec[g] === '[') {
          const j = skipGroup(spec, g);
          if (j !== -1) {
            const opts = spec.slice(g + 1, j - 1);
            const h = /(?:^|,)\s*(?:halign\s*=\s*)?([lcr])\s*(?:,|$)/.exec(opts);
            if (h) align = alignFromLetter(h[1]);
            end = j;
          }
        }
      }
      push({ align: pendingAlign ?? align, letter: pendingAlign ? null : letter, from, to: end });
      i = end;
      continue;
    }
    i++;
  }
  return { columns, vrules, vruleRanges };
}

// ---- Rules ----

const HEAVY_RULES = new Set(['toprule', 'bottomrule', 'specialrule', 'Xhline']);
const FULL_RULES = new Set(['hline', 'hdashline', 'toprule', 'midrule', 'bottomrule', 'specialrule', 'Xhline', 'hhline']);
const PARTIAL_RULES = new Set(['cline', 'cmidrule', 'cdashline']);
/** Row-prefix commands that draw nothing but must not be read as a cell. */
const SILENT_PREFIX = new Set([
  'addlinespace',
  'morecmidrules',
  'noalign',
  'endhead',
  'endfirsthead',
  'endfoot',
  'endlastfoot',
  'pagebreak',
  'nopagebreak',
]);

/**
 * Leading rule commands from `i`: the rules, where they stop, and their
 * source span. Stops at the first token that is not a rule.
 */
function readRules(
  text: string,
  i: number,
  end: number,
): { rules: TexRule[]; next: number; range: { from: number; to: number } | null } {
  const rules: TexRule[] = [];
  let first = -1;
  let last = -1;
  for (;;) {
    const at = skipSpaceAndComments(text, i, end);
    const cmd = readCommand(text, at);
    if (!cmd || cmd.end > end) break;
    const { name } = cmd;
    if (!FULL_RULES.has(name) && !PARTIAL_RULES.has(name) && !SILENT_PREFIX.has(name)) break;
    let j = cmd.end;
    let partial: { from: number; to: number } | null = null;
    // Optional `[w]` and `(trim)`, then the required args.
    for (;;) {
      const g = skipSpace(text, j, end);
      if (text[g] === '[' || (text[g] === '(' && name === 'cmidrule')) {
        const k = skipGroup(text, g, end);
        if (k === -1) break;
        j = k;
        continue;
      }
      break;
    }
    const argc =
      name === 'specialrule' ? 3 : PARTIAL_RULES.has(name) || name === 'Xhline' || name === 'hhline' || name === 'noalign' ? 1 : 0;
    for (let a = 0; a < argc; a++) {
      const g = skipSpace(text, j, end);
      if (text[g] !== '{') break;
      const k = skipGroup(text, g, end);
      if (k === -1) break;
      if (PARTIAL_RULES.has(name)) {
        const m = /^\s*(\d+)\s*-\s*(\d+)\s*$/.exec(text.slice(g + 1, k - 1));
        if (m) partial = { from: parseInt(m[1], 10) - 1, to: parseInt(m[2], 10) - 1 };
      }
      j = k;
    }
    if (first === -1) first = at;
    last = j;
    if (FULL_RULES.has(name)) {
      rules.push({ weight: HEAVY_RULES.has(name) ? 'heavy' : 'thin', from: 0, to: Infinity });
    } else if (PARTIAL_RULES.has(name) && partial) {
      rules.push({ weight: 'thin', ...partial });
    }
    i = j;
  }
  return {
    rules,
    next: first === -1 ? i : last,
    range: first === -1 ? null : { from: first, to: last },
  };
}

// ---- Cells ----

/** `\multicolumn{n}{spec}{content}` / `\multirow{n}[x]{w}[y]{content}`
 *  filling the whole trimmed cell. */
function readSpanCommand(
  text: string,
  from: number,
  to: number,
): Pick<TexCell, 'editFrom' | 'editTo' | 'span' | 'spanArg' | 'align' | 'multirow'> | null {
  const cmd = readCommand(text, from);
  if (!cmd || (cmd.name !== 'multicolumn' && cmd.name !== 'multirow')) return null;
  const groups: Array<{ from: number; to: number }> = [];
  let j = cmd.end;
  const want = 3;
  while (groups.length < want) {
    const g = skipSpace(text, j, to);
    if (text[g] === '[' && cmd.name === 'multirow') {
      const k = skipGroup(text, g, to);
      if (k === -1) return null;
      j = k;
      continue;
    }
    if (text[g] !== '{') return null;
    const k = skipGroup(text, g, to);
    if (k === -1) return null;
    groups.push({ from: g + 1, to: k - 1 });
    j = k;
  }
  // The command must be the whole cell, or edits to its argument would
  // silently drop the rest.
  if (skipSpaceAndComments(text, j, to) < to) return null;
  const content = groups[2];
  if (cmd.name === 'multirow') {
    return { editFrom: content.from, editTo: content.to, span: 1, spanArg: null, align: null, multirow: true };
  }
  const n = parseInt(text.slice(groups[0].from, groups[0].to).trim(), 10);
  if (!Number.isFinite(n) || n < 1) return null;
  const spec = parseColumnSpec(expandSpecRepeats(text.slice(groups[1].from, groups[1].to)));
  // A multicolumn wrapping a multirow edits the inner content.
  const inner = readSpanCommand(text, skipSpace(text, content.from, content.to), trimEnd(text, content.from, content.to));
  return {
    editFrom: inner?.multirow ? inner.editFrom : content.from,
    editTo: inner?.multirow ? inner.editTo : content.to,
    span: n,
    spanArg: groups[0],
    align: spec.columns[0]?.align ?? null,
    multirow: inner?.multirow ?? false,
  };
}

function trimEnd(text: string, from: number, to: number): number {
  while (to > from && isSpace(text[to - 1])) to--;
  return to;
}

// ---- Table scan ----

interface RawRow {
  from: number;
  amps: number[];
  endFrom: number;
  endTo: number;
}

/**
 * Parse the environment whose `\begin` is at `start`, or null when it is
 * malformed (unbalanced braces, a stray `\end`, no closing `\end{env}`):
 * a table we can't read exactly is left as source.
 */
export function parseTexTable(text: string, start: number, env: string): TexTable | null {
  const required = TABLE_ENVS[env];
  if (required === undefined) return null;
  let i = start + `\\begin{${env}}`.length;

  // Arguments: optional `[…]` anywhere, `required` braced ones; the spec is
  // the last.
  let braced = 0;
  let specFrom = -1;
  let specTo = -1;
  while (braced < required) {
    const g = skipSpaceAndComments(text, i);
    if (text[g] === '[') {
      const k = skipGroup(text, g);
      if (k === -1) return null;
      i = k;
      continue;
    }
    if (text[g] !== '{') return null;
    const k = skipGroup(text, g);
    if (k === -1) return null;
    braced++;
    if (braced === required) {
      specFrom = g + 1;
      specTo = k - 1;
    }
    i = k;
  }
  const bodyFrom = i;

  // Body: split rows on `\\` and cells on `&`, both at brace depth 0 outside
  // nested environments.
  const raws: RawRow[] = [];
  let depth = 0;
  const envs: string[] = [];
  let row: RawRow = { from: bodyFrom, amps: [], endFrom: -1, endTo: -1 };
  let bodyTo = -1;
  let to = -1;
  const n = text.length;
  while (i < n) {
    const ch = text[i];
    if (ch === '%') {
      while (i < n && text[i] !== '\n') i++;
      continue;
    }
    if (ch === '\\') {
      if (text[i + 1] === '\\') {
        if (depth === 0 && envs.length === 0) {
          let j = i + 2;
          if (text[j] === '*') j++;
          let endTo = j;
          let g = j;
          while (text[g] === ' ' || text[g] === '\t') g++;
          if (text[g] === '[') {
            const k = skipGroup(text, g);
            if (k !== -1) endTo = k;
          }
          row.endFrom = i;
          row.endTo = endTo;
          raws.push(row);
          row = { from: endTo, amps: [], endFrom: -1, endTo: -1 };
          i = endTo;
          continue;
        }
        i += 2;
        continue;
      }
      const cmd = readCommand(text, i);
      if (!cmd) {
        i += 2;
        continue;
      }
      if (cmd.name === 'begin' || cmd.name === 'end') {
        const g = skipSpace(text, cmd.end);
        const k = text[g] === '{' ? skipGroup(text, g) : -1;
        if (k === -1) return null;
        const name = text.slice(g + 1, k - 1).trim();
        if (cmd.name === 'begin') {
          envs.push(name);
        } else if (envs.length === 0) {
          if (name !== env || depth !== 0) return null;
          bodyTo = i;
          to = k;
          break;
        } else {
          if (envs[envs.length - 1] !== name) return null;
          envs.pop();
        }
        i = k;
        continue;
      }
      if (cmd.name === 'tabularnewline' && depth === 0 && envs.length === 0) {
        row.endFrom = i;
        row.endTo = cmd.end;
        raws.push(row);
        row = { from: cmd.end, amps: [], endFrom: -1, endTo: -1 };
      }
      i = cmd.end;
      continue;
    }
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth < 0) return null;
    } else if (ch === '&' && depth === 0 && envs.length === 0) {
      row.amps.push(i);
    }
    i++;
  }
  if (bodyTo === -1) return null;
  row.endFrom = row.endTo = bodyTo;
  raws.push(row);

  const rows: TexRow[] = [];
  let trailingRules: TexRule[] = [];
  let trailingRulesRange: { from: number; to: number } | null = null;
  raws.forEach((raw, idx) => {
    const last = idx === raws.length - 1;
    const segEnd = raw.amps[0] ?? raw.endFrom;
    const { rules, next, range } = readRules(text, raw.from, segEnd);
    const empty = raw.amps.length === 0 && skipSpaceAndComments(text, next, raw.endFrom) >= raw.endFrom;
    if (last && empty) {
      trailingRules = rules;
      trailingRulesRange = range;
      return;
    }
    const bounds = [next, ...raw.amps.map((a) => a + 1)];
    const cells: TexCell[] = [];
    let col = 0;
    bounds.forEach((segFrom, k) => {
      const segTo = k < raw.amps.length ? raw.amps[k] : raw.endFrom;
      const from = skipSpace(text, segFrom, segTo);
      const cellTo = Math.max(from, trimEnd(text, from, segTo));
      const span = readSpanCommand(text, from, cellTo);
      cells.push({
        segFrom,
        segTo,
        from,
        to: cellTo,
        editFrom: span?.editFrom ?? from,
        editTo: span?.editTo ?? cellTo,
        span: span?.span ?? 1,
        spanArg: span?.spanArg ?? null,
        col,
        align: span?.align ?? null,
        multirow: span?.multirow ?? false,
        ampAfter: k < raw.amps.length ? raw.amps[k] : -1,
      });
      col += span?.span ?? 1;
    });
    rows.push({
      from: raw.from,
      contentFrom: next,
      rules,
      rulesRange: range,
      cells,
      endFrom: raw.endFrom,
      endTo: raw.endTo,
    });
  });

  // The spec: tblr's may be key-value (`colspec={…}, hlines`).
  let specText = text.slice(specFrom, specTo);
  let specOffset = specFrom;
  let allHLines = false;
  let allVLines = false;
  let specEditable = true;
  if (env.endsWith('tblr') && /=|\bhlines\b|\bvlines\b/.test(specText)) {
    allHLines = /(?:^|,)\s*hlines\b/.test(specText);
    allVLines = /(?:^|,)\s*vlines\b/.test(specText);
    const m = /colspec\s*=\s*\{/.exec(specText);
    const g = m ? m.index + m[0].length - 1 : -1;
    const k = g === -1 ? -1 : skipGroup(specText, g);
    if (k !== -1) {
      specOffset = specFrom + g + 1;
      specText = specText.slice(g + 1, k - 1);
    } else {
      specText = '';
      specEditable = false;
    }
  }
  const relative = parseColumnSpec(specText);
  const spec: ColumnSpec = {
    columns: relative.columns.map((c) => ({
      ...c,
      from: c.from + specOffset,
      to: c.to + specOffset,
      letter: c.letter ? { from: c.letter.from + specOffset, to: c.letter.to + specOffset } : null,
    })),
    vrules: relative.vrules,
    vruleRanges: relative.vruleRanges.map((r) => (r ? { from: r.from + specOffset, to: r.to + specOffset } : null)),
  };
  const widest = Math.max(0, ...rows.map((r) => r.cells.reduce((s, c) => s + c.span, 0)));
  return {
    env,
    from: start,
    to,
    specFrom: specEditable ? specOffset : -1,
    specTo: specEditable ? specOffset + specText.length : -1,
    spec,
    rows,
    trailingRules,
    trailingRulesRange,
    ncols: Math.max(1, spec.columns.length, widest),
    allHLines,
    allVLines,
  };
}

/** Every well-formed top-level table in `text`, in document order. */
export function scanTexTables(text: string): TexTable[] {
  if (!text.includes('\\begin{t') && !text.includes('\\begin{l')) return [];
  const skip: Array<[number, number]> = [];
  VERBATIM_ENV.lastIndex = 0;
  for (let m = VERBATIM_ENV.exec(text); m; m = VERBATIM_ENV.exec(text)) {
    skip.push([m.index, m.index + m[0].length]);
  }
  const tables: TexTable[] = [];
  BEGIN_TABLE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = BEGIN_TABLE.exec(text)) !== null) {
    const at = m.index;
    if (skip.some(([a, b]) => at >= a && at < b)) continue;
    if (inComment(text, at)) continue;
    const t = parseTexTable(text, at, m[1]);
    if (!t) continue;
    tables.push(t);
    // Nested tables belong to the outer one's cells.
    BEGIN_TABLE.lastIndex = t.to;
  }
  return tables;
}

/** `scanTexTables` over a document, cached per `Text`. */
export const texTablesOf = memoByDoc((doc: Text): TexTable[] => scanTexTables(docText(doc)));

// ---- Edits ----

/**
 * Cell text as typed to cell source. A bare `%` would comment out the rest of
 * the row and a top-level `&` would split the cell, so both are escaped,
 * unless the cell already carried a comment (then the user is writing raw
 * source on purpose and the text goes in verbatim).
 */
export function cellTextToSource(text: string, original: string): string {
  const t = text.replace(/\r\n?/g, '\n').trim();
  if (hasComment(original)) return t;
  let out = '';
  let depth = 0;
  let math = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    if (ch === '\\' && i + 1 < t.length) {
      out += ch + t[i + 1];
      i++;
      continue;
    }
    if (ch === '{') depth++;
    else if (ch === '}') depth = Math.max(0, depth - 1);
    else if (ch === '$') math = !math;
    if (ch === '%' || (ch === '&' && depth === 0 && !math)) {
      out += '\\' + ch;
      continue;
    }
    out += ch;
  }
  return out;
}

/** The change writing `text` into `cell`, or null when nothing changes. */
export function cellEdit(source: string, cell: TexCell, text: string): TexChange | null {
  const original = source.slice(cell.editFrom, cell.editTo);
  const insert = cellTextToSource(text, original);
  if (insert === original) return null;
  if (insert === '' || cell.editFrom !== cell.editTo || cell.spanArg !== null || cell.multirow) {
    return { from: cell.editFrom, to: cell.editTo, insert };
  }
  // An empty cell: replace its blank segment so the text sits one space from
  // each delimiter (`& b &`), keeping any line break and indent before it.
  const seg = source.slice(cell.segFrom, cell.segTo);
  const nl = seg.lastIndexOf('\n');
  const from = nl === -1 ? cell.segFrom : cell.segFrom + nl + 1;
  const before = source[from - 1];
  const lead =
    nl !== -1 ? /^[ \t]*/.exec(seg.slice(nl + 1))![0] : before !== undefined && !isSpace(before) ? ' ' : '';
  const after = source[cell.segTo];
  const trail = after === '&' || after === '\\' ? ' ' : '';
  return { from, to: cell.segTo, insert: lead + insert + trail };
}

function lineStart(text: string, pos: number): number {
  return text.lastIndexOf('\n', pos - 1) + 1;
}

function lineEnd(text: string, pos: number): number {
  const k = text.indexOf('\n', pos);
  return k === -1 ? text.length : k;
}

function indentOf(text: string, pos: number): string {
  const ls = lineStart(text, pos);
  return /^[ \t]*/.exec(text.slice(ls))![0];
}

function emptyRowText(ncols: number): string {
  return ncols <= 1 ? '' : Array(ncols - 1).fill('&').join(' ');
}

/** `[from, to)` grown to whole lines when only whitespace or a comment sits
 *  around it, so deleting a row doesn't leave a blank line. */
function growToLines(text: string, from: number, to: number): { from: number; to: number } {
  const ls = lineStart(text, from);
  const le = lineEnd(text, to);
  if (text.slice(ls, from).trim() === '' && stripComments(text.slice(to, le)).trim() === '') {
    return { from: ls, to: Math.min(text.length, le + 1) };
  }
  return { from, to };
}

export function insertRowEdit(source: string, t: TexTable, r: number, where: 'above' | 'below'): TexChange[] {
  const row = t.rows[r];
  if (!row) return [];
  const cells = emptyRowText(t.ncols);
  const firstCell = row.cells[0]?.from ?? row.contentFrom;
  const indent = indentOf(source, firstCell);
  if (where === 'above') {
    const ls = lineStart(source, firstCell);
    if (source.slice(ls, firstCell).trim() === '') {
      return [{ from: ls, to: ls, insert: `${indent}${cells} \\\\\n` }];
    }
    return [{ from: firstCell, to: firstCell, insert: `${cells} \\\\\n${indent}` }];
  }
  if (row.endFrom === row.endTo) {
    // The last row has no `\\`: give it one, and the new row none, keeping
    // the table's style.
    const at = row.cells[row.cells.length - 1]?.to ?? row.contentFrom;
    return [{ from: at, to: at, insert: ` \\\\\n${indent}${cells}` }];
  }
  const le = lineEnd(source, row.endTo);
  const at = stripComments(source.slice(row.endTo, le)).trim() === '' ? le : row.endTo;
  return [{ from: at, to: at, insert: `\n${indent}${cells} \\\\` }];
}

export function deleteRowEdit(source: string, t: TexTable, r: number): TexChange[] {
  const row = t.rows[r];
  if (!row || t.rows.length <= 1) return [];
  const from = row.cells[0]?.from ?? row.contentFrom;
  let to = row.endTo;
  if (row.endFrom === row.endTo) {
    // Last row without `\\`: drop the previous row's terminator instead, so
    // no empty row is left behind.
    const prev = t.rows[r - 1];
    if (!prev) return [];
    return [{ from: prev.endFrom, to: row.cells[row.cells.length - 1].to, insert: '' }];
  }
  const g = growToLines(source, from, to);
  to = g.to;
  return [{ from: g.from, to, insert: '' }];
}

/** Rewrite the spec text through `op`, expanding `*{n}{…}` first when the
 *  columns it touches sit in a repeat. */
function specChange(
  source: string,
  t: TexTable,
  op: (spec: string, parsed: ColumnSpec) => string | null,
): TexChange | null {
  if (t.specFrom < 0) return null;
  const original = source.slice(t.specFrom, t.specTo);
  const spec = original.includes('*') ? expandSpecRepeats(original) : original;
  const next = op(spec, parseColumnSpec(spec));
  if (next === null || next === original) return null;
  return { from: t.specFrom, to: t.specTo, insert: next };
}

const ALIGN_LETTER: Record<TexAlign, string> = { left: 'l', center: 'c', right: 'r' };

/** Insert an empty column at logical position `p` (0..ncols). */
export function insertColumnEdit(source: string, t: TexTable, p: number): TexChange[] {
  const changes: TexChange[] = [];
  const spec = specChange(source, t, (s, parsed) => {
    const cols = parsed.columns;
    if (cols.length === 0) return null;
    const neighbour = cols[Math.min(p, cols.length - 1)];
    const letter = neighbour.letter ? s.slice(neighbour.letter.from, neighbour.letter.to) : ALIGN_LETTER[neighbour.align];
    const at = p === 0 ? cols[0].from : cols[Math.min(p, cols.length) - 1].to;
    return s.slice(0, at) + letter + s.slice(at);
  });
  if (spec) changes.push(spec);
  for (const row of t.rows) {
    const total = row.cells.reduce((s, c) => s + c.span, 0);
    const starting = row.cells.find((c) => c.col === p);
    if (starting) {
      changes.push({ from: starting.from, to: starting.from, insert: '& ' });
      continue;
    }
    const spanning = row.cells.find((c) => c.col < p && p < c.col + c.span);
    if (spanning?.spanArg) {
      changes.push({ ...spanning.spanArg, insert: String(spanning.span + 1) });
      continue;
    }
    if (p === total && row.cells.length > 0) {
      const last = row.cells[row.cells.length - 1];
      changes.push({ from: last.to, to: last.to, insert: ' &' });
    }
  }
  return sortChanges(changes);
}

export function deleteColumnEdit(source: string, t: TexTable, c: number): TexChange[] {
  if (t.ncols <= 1) return [];
  const changes: TexChange[] = [];
  const spec = specChange(source, t, (s, parsed) => {
    const col = parsed.columns[c];
    if (!col) return null;
    let from = col.from;
    let to = col.to;
    // `|l|c|` minus `c` is `|l|`, not `|l||`: drop one side's rules.
    const left = parsed.vruleRanges[c];
    const right = parsed.vruleRanges[c + 1];
    if (left && right) {
      if (c === parsed.columns.length - 1) from = left.from;
      else to = right.to;
    }
    return s.slice(0, from) + s.slice(to);
  });
  if (spec) changes.push(spec);
  for (const row of t.rows) {
    const k = row.cells.findIndex((x) => x.col <= c && c < x.col + x.span);
    if (k === -1) continue;
    const cell = row.cells[k];
    if (cell.span > 1 && cell.spanArg) {
      changes.push({ ...cell.spanArg, insert: String(cell.span - 1) });
      continue;
    }
    if (cell.ampAfter !== -1) {
      const next = row.cells[k + 1];
      changes.push({ from: cell.from, to: next ? next.from : cell.ampAfter + 1, insert: '' });
    } else if (k > 0) {
      const prev = row.cells[k - 1];
      changes.push({ from: prev.to, to: cell.to, insert: '' });
    } else {
      changes.push({ from: cell.from, to: cell.to, insert: '' });
    }
  }
  return sortChanges(changes);
}

/** Set column `c`'s alignment. Only plain `l`/`c`/`r` columns are
 *  rewritten; paragraph and package columns return no change. */
export function setAlignEdit(source: string, t: TexTable, c: number, align: TexAlign): TexChange[] {
  const change = specChange(source, t, (s, parsed) => {
    const col = parsed.columns[c];
    if (!col?.letter) return null;
    return s.slice(0, col.letter.from) + ALIGN_LETTER[align] + s.slice(col.letter.to);
  });
  return change ? [change] : [];
}

/** Whether column `c` has an alignment `setAlignEdit` can change. */
export function canSetAlign(t: TexTable, c: number): boolean {
  return t.specFrom >= 0 && t.spec.columns[c]?.letter != null;
}

/** Whether the table uses booktabs rules, so new rules match. */
function usesBooktabs(source: string, t: TexTable): boolean {
  return /\\(?:top|mid|bottom|cmid)rule\b/.test(source.slice(t.from, t.to));
}

/**
 * Toggle the rule under row `r`: remove the rules there if any, else add a
 * `\midrule` (or `\hline` in a table without booktabs).
 */
export function toggleRuleBelowEdit(source: string, t: TexTable, r: number): TexChange[] {
  const row = t.rows[r];
  if (!row) return [];
  const next = t.rows[r + 1];
  const range = next ? next.rulesRange : t.trailingRulesRange;
  if (range) {
    const g = growToLines(source, range.from, range.to);
    return [{ from: g.from, to: g.to, insert: '' }];
  }
  const rule = usesBooktabs(source, t) ? (next ? '\\midrule' : '\\bottomrule') : '\\hline';
  const indent = indentOf(source, row.cells[0]?.from ?? row.contentFrom);
  if (row.endFrom === row.endTo) {
    const at = row.cells[row.cells.length - 1]?.to ?? row.contentFrom;
    return [{ from: at, to: at, insert: ` \\\\\n${indent}${rule}` }];
  }
  const le = lineEnd(source, row.endTo);
  const at = stripComments(source.slice(row.endTo, le)).trim() === '' ? le : row.endTo;
  return [{ from: at, to: at, insert: `\n${indent}${rule}` }];
}

function sortChanges(changes: TexChange[]): TexChange[] {
  return changes.sort((a, b) => a.from - b.from || a.to - b.to);
}

/** The table starting at or containing `pos`. */
export function tableAt(tables: readonly TexTable[], pos: number): TexTable | null {
  return tables.find((t) => t.from <= pos && pos <= t.to) ?? null;
}
