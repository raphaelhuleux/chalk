import { describe, it, expect, vi } from 'vitest';
import { parseHSnips } from '../src/editor/hsnips-parser';

const GOOD = `snippet ;; "Inline math" iA
\\$$0\\$
endsnippet
`;

describe('regex trigger anchoring', () => {
  // Every regex trigger is implicitly anchored to the cursor: `findMatch`
  // execs it against the text up to the caret and replaces from the match
  // start to the caret. A pattern that escapes the anchor slot — or splits it
  // across a top-level alternation — must not end up matching mid-line, or
  // the expansion swallows everything between the match and the caret.
  const parseTrigger = (pattern: string) =>
    parseHSnips(`snippet \`${pattern}\` "t" Ai\nX\nendsnippet\n`)[0].regexp!;

  it('anchors a pattern whose trailing $ is an escaped literal dollar', () => {
    const re = parseTrigger('([a-z])\\$');
    // Must not match with trailing text after the literal dollar.
    expect(re.exec('a$ and more text')).toBeNull();
    expect(re.exec('a$')).not.toBeNull();
  });

  it('anchors the whole pattern, not just the last alternative', () => {
    const re = parseTrigger('foo|bar');
    expect(re.exec('foo then more')).toBeNull();
    expect(re.exec('xxfoo')).not.toBeNull();
    expect(re.exec('xxbar')).not.toBeNull();
  });

  it('leaves an already-anchored pattern behaving the same', () => {
    const re = parseTrigger('([a-z])sr$');
    expect(re.exec('asr')).not.toBeNull();
    expect(re.exec('asr tail')).toBeNull();
  });

  it('keeps capture-group numbering intact', () => {
    const re = parseTrigger('([a-z])(\\d)');
    const m = re.exec('x7');
    expect(m?.[1]).toBe('x');
    expect(m?.[2]).toBe('7');
  });
});

describe('parseHSnips resilience', () => {
  it('skips a snippet whose regex does not compile and keeps the rest', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const content =
      GOOD +
      '\nsnippet `([a-z` "broken" A\n\\bad{#1}\nendsnippet\n' +
      '\nsnippet te "text" A\n\\text{$0}\nendsnippet\n';

    const parsed = parseHSnips(content);

    expect(parsed.map((s) => s.trigger)).toEqual([';;', 'te']);
    expect(warn).toHaveBeenCalledOnce();
    warn.mockRestore();
  });

  it('does not leak the skipped snippet body into the snippet list', () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const content = 'snippet `([a-z` "broken" A\nsnippet-looking body\nendsnippet\n' + GOOD;
    const parsed = parseHSnips(content);
    expect(parsed).toHaveLength(1);
    expect(parsed[0].trigger).toBe(';;');
    vi.restoreAllMocks();
  });
});
