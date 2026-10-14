import { describe, it, expect } from 'vitest';
import { resolveScopeColor } from '../../src/extension/theme-reader';

describe('resolveScopeColor', () => {
  it('returns null when no entry matches', () => {
    const tokens = [
      { scope: 'keyword', settings: { foreground: '#f00' } },
    ];
    expect(resolveScopeColor('string.quoted', tokens)).toBeNull();
  });

  it('matches on exact scope', () => {
    const tokens = [
      { scope: 'keyword', settings: { foreground: '#abc' } },
    ];
    expect(resolveScopeColor('keyword', tokens)).toBe('#abc');
  });

  it('matches when token scope is a dot-prefix of the target', () => {
    const tokens = [
      { scope: 'keyword.control', settings: { foreground: '#cc0' } },
    ];
    expect(resolveScopeColor('keyword.control.latex', tokens)).toBe('#cc0');
  });

  it('prefers longer-prefix matches over shorter ones', () => {
    const tokens = [
      { scope: 'keyword', settings: { foreground: '#111' } },
      { scope: 'keyword.control', settings: { foreground: '#222' } },
    ];
    expect(resolveScopeColor('keyword.control.latex', tokens)).toBe('#222');
  });

  it('on a score tie, the later entry wins (CSS-style cascade)', () => {
    const tokens = [
      { scope: 'keyword', settings: { foreground: '#111' } },
      { scope: 'keyword', settings: { foreground: '#222' } },
    ];
    expect(resolveScopeColor('keyword.control', tokens)).toBe('#222');
  });

  it('accepts an array of scopes', () => {
    const tokens = [
      {
        scope: ['string', 'comment'],
        settings: { foreground: '#6a9955' },
      },
    ];
    expect(resolveScopeColor('comment.line.percentage', tokens)).toBe(
      '#6a9955',
    );
  });

  it('accepts comma-separated scopes in a single string', () => {
    const tokens = [
      {
        scope: 'string, comment.line',
        settings: { foreground: '#6a9955' },
      },
    ];
    expect(resolveScopeColor('comment.line.percentage', tokens)).toBe(
      '#6a9955',
    );
  });

  it('skips entries without a foreground setting', () => {
    const tokens = [
      { scope: 'keyword', settings: { fontStyle: 'italic' } },
      { scope: 'keyword', settings: { foreground: '#333' } },
    ];
    expect(resolveScopeColor('keyword.control', tokens)).toBe('#333');
  });

  it('does not match on non-aligned substring', () => {
    // "key" is NOT a dot-segment prefix of "keyword".
    const tokens = [{ scope: 'key', settings: { foreground: '#f00' } }];
    expect(resolveScopeColor('keyword', tokens)).toBeNull();
  });

  it('does not match when source scope is longer than target', () => {
    const tokens = [
      { scope: 'keyword.control.latex', settings: { foreground: '#f00' } },
    ];
    expect(resolveScopeColor('keyword.control', tokens)).toBeNull();
  });
});
