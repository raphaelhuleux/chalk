import type { HeadingColors } from '@chalk/editor-core';
import {
  loadActiveTheme,
  resolveScopeColor,
  type RawTokenColor,
} from './theme-reader';

export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;

/**
 * The color for one heading level; candidates run most specific first.
 * Exported for unit tests.
 */
export function pickHeadingColor(
  level: HeadingLevel,
  tokens: RawTokenColor[],
): string | undefined {
  const candidates = [
    `markup.heading.${level}.markdown`,
    // Catppuccin (and others) scope per-level headings without `markup.`;
    // dot-aligned prefix matching needs this spelled out.
    `heading.${level}.markdown`,
    `entity.name.section.markdown`,
    `markup.heading.markdown`,
    `markup.heading`,
    `heading`,
  ];
  for (const scope of candidates) {
    const color = resolveScopeColor(scope, tokens);
    if (color) return color;
  }
  return undefined;
}

/**
 * Best-effort heading colors from the active theme, following its `include`
 * chain. Empty when the theme can't be read or has no matching rules; the
 * webview falls back to its CSS variables.
 */
export async function getMarkdownHeadingColors(): Promise<HeadingColors> {
  const { tokens } = await loadActiveTheme();
  if (tokens.length === 0) return {};

  const result: HeadingColors = {};
  for (const level of [1, 2, 3, 4, 5, 6] as const) {
    const color = pickHeadingColor(level, tokens);
    if (color) result[level] = color;
  }
  return result;
}
