import { readFileSync } from 'node:fs';
import { URL as NodeURL } from 'node:url';
import { describe, it, expect } from 'vitest';
import { _testing } from '../src/editor/hsnips-plugin';
import { parseHSnips } from '../src/editor/hsnips-parser';

const { processBody } = _testing;

// groups[0] is the full match, as returned by RegExp.exec.
describe('regex capture substitution', () => {
  it('substitutes #1 with the first capture', () => {
    expect(processBody('\\bar{#1}', 0, ['xbar', 'x']).text).toBe('\\bar{x}');
  });

  it('substitutes multiple captures', () => {
    expect(processBody('#1_{#2}', 0, ['ab', 'a', 'b']).text).toBe('a_{b}');
  });

  it('substitutes a capture index past the end with nothing', () => {
    expect(processBody('\\bar{#3}', 0, ['xbar', 'x']).text).toBe('\\bar{}');
  });

  it('leaves #N untouched for literal-trigger snippets', () => {
    expect(processBody('\\newcommand{\\x}[1]{#1}', 0, []).text).toBe(
      '\\newcommand{\\x}[1]{#1}',
    );
  });

  it('leaves # alone when it is not followed by a digit', () => {
    expect(processBody('# not a capture', 0, ['m']).text).toBe('# not a capture');
  });

  it('keeps tab stops working alongside captures', () => {
    const { text, tabStops } = processBody('\\bar{#1}$0', 0, ['xbar', 'x']);
    expect(text).toBe('\\bar{x}');
    expect(tabStops).toEqual([{ from: 7, to: 7, index: 0 }]);
  });

  it('trims the captures named in trimmedCaptures', () => {
    expect(processBody('\\gets #1', 0, ['<- a', ' a '], new Set([1])).text).toBe(
      '\\gets a',
    );
  });
});

describe('rv = m[N] rewriting', () => {
  it('rewrites a capture reference to #N', () => {
    const [snippet] = parseHSnips(
      'snippet `([a-z])bar` "add bar" Ai\n\\bar{``rv = m[1]``}\nendsnippet\n',
    );
    expect(snippet.body).toBe('\\bar{#1}');
    expect(snippet.trimmedCaptures?.size ?? 0).toBe(0);
  });

  it('records .trim() variants instead of inventing body syntax', () => {
    const [snippet] = parseHSnips(
      'snippet `<-([^->])` "get" A\n\\gets ``rv = m[1].trim()``\nendsnippet\n',
    );
    expect(snippet.body).toBe('\\gets #1');
    expect(snippet.trimmedCaptures).toEqual(new Set([1]));
  });

  it('still strips JS that is not a plain capture reference', () => {
    const [snippet] = parseHSnips(
      'snippet ;x "x" A\nvalue: ``rv = 1 + 1``\nendsnippet\n',
    );
    expect(snippet.body).toBe('value: ');
  });

  it('repairs the bundled add-bar snippet end to end', () => {
    const asset = readFileSync(
      new NodeURL('../assets/latex.hsnips', import.meta.url),
      'utf8',
    );
    const bar = parseHSnips(asset).find(
      (s) => s.regexpSource === '([a-gi-zA-Z])bar',
    );
    expect(bar).toBeDefined();
    expect(bar!.body).toBe('\\bar{#1}');

    const match = bar!.regexp!.exec('xbar')!;
    expect(processBody(bar!.body, 0, Array.from(match), bar!.trimmedCaptures).text).toBe(
      '\\bar{x}',
    );
  });
});
