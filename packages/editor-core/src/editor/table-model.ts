// Pure GFM pipe-table model (no DOM, no CodeMirror): parse, serialize,
// structural ops. Cells hold raw source text (`\|` kept); escapeCell and
// unescapeCell convert to and from the plain text a cell displays.

export type Align = 'none' | 'left' | 'center' | 'right';

export interface TableModel {
  aligns: Align[];
  header: string[];
  rows: string[][];
}

/** Count code points so surrogate pairs (emoji) measure as one column. */
function displayWidth(s: string): number {
  return Array.from(s).length;
}

/**
 * Split a single pipe-table line into trimmed cells, honoring `\|` escapes and
 * the optional leading/trailing pipes GFM permits.
 */
export function splitRow(line: string): string[] {
  const trimmed = line.trim();
  const cells: string[] = [];
  let cur = '';
  for (let i = 0; i < trimmed.length; i++) {
    const ch = trimmed[i];
    if (ch === '\\' && i + 1 < trimmed.length) {
      cur += ch + trimmed[i + 1];
      i++;
      continue;
    }
    if (ch === '|') {
      cells.push(cur);
      cur = '';
      continue;
    }
    cur += ch;
  }
  cells.push(cur);

  // Drop the empty edge segments a leading/trailing `|` produces.
  if (cells.length > 1 && cells[0].trim() === '' && trimmed.startsWith('|')) {
    cells.shift();
  }
  if (cells.length > 1 && cells[cells.length - 1].trim() === '' && trimmed.endsWith('|')) {
    cells.pop();
  }
  return cells.map((c) => c.trim());
}

function parseAlign(cell: string): Align {
  const c = cell.trim();
  const left = c.startsWith(':');
  const right = c.endsWith(':');
  if (left && right) return 'center';
  if (right) return 'right';
  if (left) return 'left';
  return 'none';
}

/** Pad every part to the widest column count seen (lossless). */
export function normalizeShape(m: TableModel): TableModel {
  const cols = Math.max(
    1,
    m.header.length,
    m.aligns.length,
    ...m.rows.map((r) => r.length),
  );
  const pad = (arr: string[]): string[] => {
    const out = arr.slice(0, cols);
    while (out.length < cols) out.push('');
    return out;
  };
  const aligns = m.aligns.slice(0, cols);
  while (aligns.length < cols) aligns.push('none');
  return {
    aligns,
    header: pad(m.header),
    rows: m.rows.map(pad),
  };
}

/** Parse the source slice of a GFM `Table` node: header, delimiter, body. */
export function parseTable(src: string): TableModel {
  const lines = src.split('\n');
  const header = splitRow(lines[0] ?? '');
  const aligns = (lines.length > 1 ? splitRow(lines[1]) : []).map(parseAlign);
  const rows = lines
    .slice(2)
    .filter((l) => l.trim() !== '')
    .map(splitRow);
  return normalizeShape({ aligns, header, rows });
}

function delimiterCell(align: Align, width: number): string {
  // Colons come out of the width so the source grid stays aligned.
  const w = Math.max(width, 3);
  switch (align) {
    case 'left':
      return ':' + '-'.repeat(w - 1);
    case 'right':
      return '-'.repeat(w - 1) + ':';
    case 'center':
      return ':' + '-'.repeat(w - 2) + ':';
    default:
      return '-'.repeat(w);
  }
}

function padCell(text: string, align: Align, width: number): string {
  const deficit = width - displayWidth(text);
  if (deficit <= 0) return text;
  switch (align) {
    case 'right':
      return ' '.repeat(deficit) + text;
    case 'center': {
      const left = Math.floor(deficit / 2);
      return ' '.repeat(left) + text + ' '.repeat(deficit - left);
    }
    default:
      return text + ' '.repeat(deficit);
  }
}

/** Serialize to GFM, padding columns to a uniform width unless `pad: false`. */
export function serializeTable(m: TableModel, opts: { pad?: boolean } = {}): string {
  const pad = opts.pad ?? true;
  const model = normalizeShape(m);
  const cols = model.header.length;

  let widths: number[];
  if (pad) {
    widths = [];
    for (let c = 0; c < cols; c++) {
      let w = displayWidth(model.header[c]);
      for (const row of model.rows) w = Math.max(w, displayWidth(row[c]));
      widths[c] = Math.max(w, 3); // delimiter needs ≥3 dashes
    }
  } else {
    widths = new Array(cols).fill(0);
  }

  const renderRow = (cells: string[]): string => {
    const out = cells.map((cell, c) => (pad ? padCell(cell, model.aligns[c], widths[c]) : cell));
    return '| ' + out.join(' | ') + ' |';
  };
  const renderDelimiter = (): string => {
    const out = model.aligns.map((a, c) => delimiterCell(a, pad ? widths[c] : 3));
    return '| ' + out.join(' | ') + ' |';
  };

  const lines = [renderRow(model.header), renderDelimiter(), ...model.rows.map(renderRow)];
  return lines.join('\n');
}

// ---- Cell text <-> source escaping ----

/**
 * Source to cell text. Decodes pairs left to right like splitRow, not with
 * sequential regex replaces, so `\\|` is an escaped backslash then a pipe.
 * Only `\\` and `\|` are decoded; any other `\x` stays verbatim.
 */
export function unescapeCell(raw: string): string {
  let out = '';
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (ch === '\\' && i + 1 < raw.length) {
      const next = raw[i + 1];
      if (next === '\\' || next === '|') {
        out += next;
        i++;
        continue;
      }
    }
    out += ch;
  }
  return out;
}

/**
 * Cell text to source. Backslashes must be doubled before pipes are escaped,
 * or a literal `\|` serializes as `\\|`, which splitRow reads as an escaped
 * backslash plus a real `|`, splitting the cell.
 */
export function escapeCell(text: string): string {
  return text
    .replace(/\r?\n/g, ' ')
    .replace(/\\/g, '\\\\')
    .replace(/\|/g, '\\|')
    .trim();
}

// ---- Structural ops: all return a new model, never mutate ----

function emptyRow(cols: number): string[] {
  return new Array(cols).fill('');
}

/** Insert an empty body row relative to body index `at` (-1 = header). */
export function insertRow(m: TableModel, at: number, where: 'above' | 'below'): TableModel {
  const model = normalizeShape(m);
  const rows = model.rows.slice();
  let index = where === 'above' ? at : at + 1;
  index = Math.max(0, Math.min(index, rows.length));
  rows.splice(index, 0, emptyRow(model.header.length));
  return { ...model, rows };
}

export function deleteRow(m: TableModel, at: number): TableModel {
  const model = normalizeShape(m);
  if (at < 0 || at >= model.rows.length) return model;
  const rows = model.rows.slice();
  rows.splice(at, 1);
  return { ...model, rows };
}

export function insertCol(m: TableModel, at: number, where: 'left' | 'right'): TableModel {
  const model = normalizeShape(m);
  let index = where === 'left' ? at : at + 1;
  index = Math.max(0, Math.min(index, model.header.length));
  const header = model.header.slice();
  header.splice(index, 0, '');
  const aligns = model.aligns.slice();
  aligns.splice(index, 0, 'none');
  const rows = model.rows.map((r) => {
    const row = r.slice();
    row.splice(index, 0, '');
    return row;
  });
  return { aligns, header, rows };
}

export function deleteCol(m: TableModel, at: number): TableModel {
  const model = normalizeShape(m);
  if (model.header.length <= 1) return model; // a table needs ≥1 column
  if (at < 0 || at >= model.header.length) return model;
  const header = model.header.slice();
  header.splice(at, 1);
  const aligns = model.aligns.slice();
  aligns.splice(at, 1);
  const rows = model.rows.map((r) => {
    const row = r.slice();
    row.splice(at, 1);
    return row;
  });
  return { aligns, header, rows };
}

export function setAlign(m: TableModel, col: number, align: Align): TableModel {
  const model = normalizeShape(m);
  if (col < 0 || col >= model.aligns.length) return model;
  const aligns = model.aligns.slice();
  aligns[col] = align;
  return { ...model, aligns };
}
