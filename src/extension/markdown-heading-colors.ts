import * as vscode from 'vscode';
import {
  findThemeFilePath,
  loadMergedTokenColors,
  type RawTokenColor,
} from './theme-reader';

export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;
export type HeadingColors = Partial<Record<HeadingLevel, string>>;

/**
 * Best-effort extraction of the active theme's markdown heading colors.
 * Async + include-chain aware (delegates to theme-reader's resolver),
 * so themes like Catppuccin and Tokyo Night that put their token colors
 * in an `include`d base file are handled correctly. Returns an empty
 * object for built-in themes (Dark+/Light+ have no on-disk path) or
 * themes with no matching rules — callers provide CSS-var fallbacks.
 */
export async function getMarkdownHeadingColors(): Promise<HeadingColors> {
  const themeName = vscode.workspace
    .getConfiguration('workbench')
    .get<string>('colorTheme');
  if (!themeName) return {};

  const themePath = findThemeFilePath(themeName);
  if (!themePath) return {};

  const tokens = await loadMergedTokenColors(themePath);
  if (tokens.length === 0) return {};

  const result: HeadingColors = {};
  for (const level of [1, 2, 3, 4, 5, 6] as const) {
    const color = findHeadingColor(tokens, level);
    if (color) result[level] = color;
  }
  return result;
}

function findHeadingColor(
  rules: RawTokenColor[],
  level: HeadingLevel,
): string | undefined {
  const target = `heading.${level}.markdown`;
  for (let i = rules.length - 1; i >= 0; i--) {
    const rule = rules[i];
    const fg = rule.settings?.foreground;
    if (!fg) continue;
    const scopes = normalizeScopes(rule.scope);
    if (scopes.some((s) => s.includes(target))) return fg;
  }
  return undefined;
}

function normalizeScopes(scope: string | string[] | undefined): string[] {
  if (!scope) return [];
  if (Array.isArray(scope)) return scope;
  return scope.split(',').map((s) => s.trim());
}
