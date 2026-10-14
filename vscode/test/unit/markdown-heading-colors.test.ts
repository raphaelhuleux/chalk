import { describe, it, expect } from 'vitest';
import { pickHeadingColor } from '../../src/extension/markdown-heading-colors';

describe('pickHeadingColor', () => {
  it('resolves per-level colors from markup.heading.N.markdown scopes', () => {
    const tokens = [
      { scope: 'markup.heading.1.markdown', settings: { foreground: '#e78284' } },
      { scope: 'markup.heading.2.markdown', settings: { foreground: '#ef9f76' } },
    ];
    expect(pickHeadingColor(1, tokens)).toBe('#e78284');
    expect(pickHeadingColor(2, tokens)).toBe('#ef9f76');
  });

  it('resolves bare heading.N.markdown scopes (Catppuccin spelling)', () => {
    // Regression: the v0.4→v0.5 switch from substring to dot-aligned
    // prefix matching dropped this spelling and every heading fell back
    // to the single CSS fallback color.
    const tokens = [
      { scope: 'heading.1.markdown', settings: { foreground: '#e78284' } },
      { scope: 'heading.2.markdown', settings: { foreground: '#ef9f76' } },
      { scope: 'heading.3.markdown', settings: { foreground: '#e5c890' } },
    ];
    expect(pickHeadingColor(1, tokens)).toBe('#e78284');
    expect(pickHeadingColor(2, tokens)).toBe('#ef9f76');
    expect(pickHeadingColor(3, tokens)).toBe('#e5c890');
  });

  it('prefers per-level scope over a generic heading scope', () => {
    const tokens = [
      { scope: 'heading', settings: { foreground: '#cccccc' } },
      { scope: 'heading.1.markdown', settings: { foreground: '#e78284' } },
    ];
    expect(pickHeadingColor(1, tokens)).toBe('#e78284');
    // Level 4 has no per-level rule — falls through to generic heading.
    expect(pickHeadingColor(4, tokens)).toBe('#cccccc');
  });

  it('returns undefined when nothing matches', () => {
    const tokens = [
      { scope: 'keyword.control', settings: { foreground: '#f00' } },
    ];
    expect(pickHeadingColor(1, tokens)).toBeUndefined();
  });

  it('ignores compound (space-separated) selectors', () => {
    const tokens = [
      {
        scope: 'heading.1.markdown punctuation.definition.heading.markdown',
        settings: { foreground: '#999999' },
      },
      { scope: 'heading.1.markdown', settings: { foreground: '#e78284' } },
    ];
    expect(pickHeadingColor(1, tokens)).toBe('#e78284');
  });
});
