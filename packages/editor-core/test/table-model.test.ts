import { describe, it, expect } from 'vitest';
import {
  splitRow,
  parseTable,
  serializeTable,
  normalizeShape,
  escapeCell,
  unescapeCell,
  insertRow,
  deleteRow,
  insertCol,
  deleteCol,
  setAlign,
  type TableModel,
} from '../src/editor/table-model';

describe('splitRow', () => {
  it('splits a fully-piped row', () => {
    expect(splitRow('| a | b | c |')).toEqual(['a', 'b', 'c']);
  });

  it('handles missing leading/trailing pipes', () => {
    expect(splitRow('a | b')).toEqual(['a', 'b']);
  });

  it('keeps escaped pipes inside a cell', () => {
    expect(splitRow('| a \\| b | c |')).toEqual(['a \\| b', 'c']);
  });

  it('parses a single-column row', () => {
    expect(splitRow('| only |')).toEqual(['only']);
  });

  it('preserves empty cells', () => {
    expect(splitRow('| a |  | c |')).toEqual(['a', '', 'c']);
  });
});

describe('parseTable', () => {
  it('parses header, alignment and body', () => {
    const m = parseTable('| Name | Score |\n|:-----|------:|\n| Ann | 92 |\n| Bob | 7 |');
    expect(m.header).toEqual(['Name', 'Score']);
    expect(m.aligns).toEqual(['left', 'right']);
    expect(m.rows).toEqual([
      ['Ann', '92'],
      ['Bob', '7'],
    ]);
  });

  it('detects center alignment', () => {
    const m = parseTable('| a | b |\n| :-: | --- |\n| 1 | 2 |');
    expect(m.aligns).toEqual(['center', 'none']);
  });

  it('normalizes ragged rows by padding', () => {
    const m = parseTable('| a | b | c |\n| - | - | - |\n| 1 |');
    expect(m.rows).toEqual([['1', '', '']]);
  });

  it('skips blank trailing lines', () => {
    const m = parseTable('| a |\n| - |\n| 1 |\n');
    expect(m.rows).toEqual([['1']]);
  });
});

describe('serializeTable', () => {
  it('round-trips an aligned table idempotently', () => {
    const src = '| Name | Score |\n| :--- | ----: |\n| Ann  | 92    |\n| Bob  | 7     |';
    const once = serializeTable(parseTable(src));
    const twice = serializeTable(parseTable(once));
    expect(once).toBe(twice);
  });

  it('pads columns to a uniform width (min 3 per column)', () => {
    const out = serializeTable(parseTable('| a | bbbb |\n| - | - |\n| cc | d |'));
    expect(out).toBe('| a   | bbbb |\n| --- | ---- |\n| cc  | d    |');
  });

  it('emits alignment markers in the delimiter row', () => {
    const m: TableModel = {
      aligns: ['left', 'center', 'right', 'none'],
      header: ['a', 'b', 'c', 'd'],
      rows: [],
    };
    const delim = serializeTable(m).split('\n')[1];
    expect(delim).toBe('| :-- | :-: | --: | --- |');
  });

  it('keeps a minimum of three dashes for narrow columns', () => {
    const out = serializeTable(parseTable('| a |\n| - |\n| b |'));
    expect(out).toBe('| a   |\n| --- |\n| b   |');
  });

  it('survives an escaped pipe round-trip', () => {
    const src = '| a \\| b | c |\n| --- | --- |\n| 1 | 2 |';
    const out = serializeTable(parseTable(src));
    expect(parseTable(out).header).toEqual(['a \\| b', 'c']);
  });
});

describe('normalizeShape', () => {
  it('pads header, aligns and rows to the widest column count', () => {
    const m = normalizeShape({ aligns: ['left'], header: ['a', 'b'], rows: [['1', '2', '3']] });
    expect(m.header).toEqual(['a', 'b', '']);
    expect(m.aligns).toEqual(['left', 'none', 'none']);
    expect(m.rows).toEqual([['1', '2', '3']]);
  });
});

describe('cell escaping', () => {
  it('unescapes pipes for display', () => {
    expect(unescapeCell('a \\| b')).toBe('a | b');
  });

  it('escapes pipes and flattens newlines on write-back', () => {
    expect(escapeCell('a | b')).toBe('a \\| b');
    expect(escapeCell('line1\nline2')).toBe('line1 line2');
  });

  // H-10: escapeCell must double backslashes BEFORE escaping pipes. Without
  // it, cell text `\|` serialized to `\\|`, which splitRow consumed as an
  // escaped-backslash pair + a REAL pipe — splitting the cell and shifting
  // every column to its right.
  it('escapes backslashes before pipes so `\\|` cannot leak a live pipe', () => {
    expect(escapeCell('\\|')).toBe('\\\\\\|'); // \| → \\ + \|
    expect(escapeCell('\\')).toBe('\\\\');
    expect(escapeCell('a\\b')).toBe('a\\\\b');
    expect(escapeCell('a\\')).toBe('a\\\\');
  });

  it('unescapes left-to-right pairwise so `\\\\|` is unambiguous', () => {
    expect(unescapeCell('\\\\\\|')).toBe('\\|'); // \\ then \| → backslash + pipe
    expect(unescapeCell('\\\\')).toBe('\\');
    expect(unescapeCell('a\\\\b')).toBe('a\\b');
    // Unknown escape pairs and a trailing lone backslash pass through verbatim.
    expect(unescapeCell('a\\b')).toBe('a\\b');
    expect(unescapeCell('a\\')).toBe('a\\');
  });

  it('round-trips display text through escape → unescape', () => {
    for (const text of ['\\|', '\\\\', 'a\\b', 'a | b', '\\']) {
      expect(unescapeCell(escapeCell(text))).toBe(text);
    }
  });

  // The empirical repro: a header cell whose DISPLAY text is `\|` must survive
  // serialize → parse with the column count unchanged.
  it('keeps the column count when a cell containing `\\|` round-trips the source', () => {
    for (const text of ['\\|', '\\\\', 'a\\b', 'a\\']) {
      const model: TableModel = {
        aligns: ['none', 'none'],
        header: [escapeCell(text), 'c'],
        rows: [['1', '2']],
      };
      const reparsed = parseTable(serializeTable(model));
      expect(reparsed.header.length).toBe(2);
      expect(reparsed.rows[0]).toEqual(['1', '2']);
      expect(unescapeCell(reparsed.header[0])).toBe(text);
    }
  });
});

describe('structural ops', () => {
  const base = parseTable('| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |');

  it('inserts a row below', () => {
    const m = insertRow(base, 0, 'below');
    expect(m.rows).toEqual([
      ['1', '2'],
      ['', ''],
      ['3', '4'],
    ]);
  });

  it('inserts a row above', () => {
    const m = insertRow(base, 0, 'above');
    expect(m.rows[0]).toEqual(['', '']);
  });

  it('deletes a row', () => {
    const m = deleteRow(base, 0);
    expect(m.rows).toEqual([['3', '4']]);
  });

  it('inserts a column to the right', () => {
    const m = insertCol(base, 0, 'right');
    expect(m.header).toEqual(['a', '', 'b']);
    expect(m.rows[0]).toEqual(['1', '', '2']);
    expect(m.aligns).toEqual(['none', 'none', 'none']);
  });

  it('deletes a column', () => {
    const m = deleteCol(base, 1);
    expect(m.header).toEqual(['a']);
    expect(m.rows).toEqual([['1'], ['3']]);
  });

  it('refuses to delete the last remaining column', () => {
    const single = parseTable('| a |\n| - |\n| 1 |');
    expect(deleteCol(single, 0).header).toEqual(['a']);
  });

  it('sets a column alignment', () => {
    const m = setAlign(base, 1, 'center');
    expect(m.aligns).toEqual(['none', 'center']);
  });
});
