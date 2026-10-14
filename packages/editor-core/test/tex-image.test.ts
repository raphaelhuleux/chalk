import { describe, it, expect } from 'vitest';
import { scanTexImages } from '../src/editor/tex-image';

describe('scanTexImages', () => {
  it('finds nothing in plain prose', () => {
    expect(scanTexImages('Just some text.')).toEqual([]);
  });

  it('matches a bare command and reports its path', () => {
    const text = '\\includegraphics{figures/plot.png}';
    expect(scanTexImages(text)).toEqual([
      { from: 0, to: text.length, path: 'figures/plot.png', widthPct: undefined },
    ]);
  });

  it('matches with options that carry no width', () => {
    const text = '\\includegraphics[angle=90]{a.pdf}';
    expect(scanTexImages(text)).toEqual([
      { from: 0, to: text.length, path: 'a.pdf', widthPct: undefined },
    ]);
  });

  it('parses width fractions of textwidth and linewidth', () => {
    expect(scanTexImages('\\includegraphics[width=0.5\\textwidth]{a}')[0]?.widthPct).toBe(50);
    expect(scanTexImages('\\includegraphics[width=.4\\linewidth]{a}')[0]?.widthPct).toBe(40);
    expect(scanTexImages('\\includegraphics[width=\\columnwidth]{a}')[0]?.widthPct).toBe(100);
  });

  it('parses width among other options and tolerates spaces', () => {
    const m = scanTexImages('\\includegraphics[trim=0 0 0 0, width = 0.75\\textwidth]{a}');
    expect(m[0]?.widthPct).toBe(75);
  });

  it('ignores absolute-length widths', () => {
    expect(scanTexImages('\\includegraphics[width=5cm]{a}')[0]?.widthPct).toBeUndefined();
  });

  it('reports offsets relative to the given text', () => {
    const text = 'before \\includegraphics{x.png} after';
    const [m] = scanTexImages(text);
    expect(text.slice(m.from, m.to)).toBe('\\includegraphics{x.png}');
  });

  it('matches multiple commands on one line', () => {
    const text = '\\includegraphics{a.png} and \\includegraphics{b.jpg}';
    expect(scanTexImages(text).map((m) => m.path)).toEqual(['a.png', 'b.jpg']);
  });

  it('matches inside caption, note, and frametitle arguments', () => {
    expect(scanTexImages('\\caption{see \\includegraphics{a.png}}')[0]?.path).toBe('a.png');
    expect(scanTexImages('\\note{\\includegraphics{n.pdf}}')[0]?.path).toBe('n.pdf');
    expect(scanTexImages('\\frametitle{\\includegraphics{t.png}}')[0]?.path).toBe('t.png');
  });

  it('skips an empty path', () => {
    expect(scanTexImages('\\includegraphics{}')).toEqual([]);
    expect(scanTexImages('\\includegraphics{   }')).toEqual([]);
  });

  it('never matches across a line break (CM6 replace decorations cannot span lines)', () => {
    expect(scanTexImages('\\includegraphics{a\n.png}')).toEqual([]);
    expect(scanTexImages('\\includegraphics[width=0.5\\textwidth\n]{a.png}')).toEqual([]);
    expect(scanTexImages('\\includegraphics\n{a.png}')).toEqual([]);
  });

  it('trims whitespace around the path', () => {
    expect(scanTexImages('\\includegraphics{ figures/plot.pdf }')[0]?.path).toBe(
      'figures/plot.pdf',
    );
  });
});
