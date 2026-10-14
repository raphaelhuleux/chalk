import { describe, expect, it, vi } from 'vitest';

// The bundled snippets import a .hsnips file through esbuild's text loader,
// which vitest cannot parse; the profile's scopes don't need them.
vi.mock('@chalk/editor-core/default-hsnips', () => ({ defaultLatexHsnips: '' }));

import { resolveScopeColor, type RawTokenColor } from '../../src/extension/theme-reader';
import { markdownProfile } from '../../src/extension/languages/markdown';

/** Dark+-shaped rules for the scopes fenced code falls under. */
const TOKENS: RawTokenColor[] = [
  { scope: 'comment', settings: { foreground: '#6a9955' } },
  { scope: 'keyword', settings: { foreground: '#569cd6' } },
  { scope: 'keyword.control', settings: { foreground: '#c586c0' } },
  { scope: 'constant.numeric', settings: { foreground: '#b5cea8' } },
  { scope: 'constant.language', settings: { foreground: '#569cd6' } },
  { scope: 'entity.name.function', settings: { foreground: '#dcdcaa' } },
  { scope: 'invalid', settings: { foreground: '#f44747' } },
];

function resolve(candidates: string[]): string | null {
  for (const scope of candidates) {
    const color = resolveScopeColor(scope, TOKENS);
    if (color) return color;
  }
  return null;
}

describe('markdown theme scopes', () => {
  // Fenced code is painted by codeHighlightStyle through --chalk-syntax-*;
  // with no candidates every md fence used the hardcoded Dark+ fallbacks.
  it('themes the tags fenced code uses', () => {
    const scopes = markdownProfile.themeScopeCandidates;
    expect(resolve(scopes.keyword)).toBe('#569cd6');
    expect(resolve(scopes.comment)).toBe('#6a9955');
    expect(resolve(scopes.number)).toBe('#b5cea8');
    expect(resolve(scopes.atom)).toBe('#569cd6');
    expect(resolve(scopes.specialVariable)).toBe('#dcdcaa');
    expect(resolve(scopes.invalid)).toBe('#f44747');
  });

  it('leaves brackets and tags on the engine fallback', () => {
    expect(markdownProfile.themeScopeCandidates.bracket).toEqual([]);
    expect(markdownProfile.themeScopeCandidates.tagName).toEqual([]);
  });
});
