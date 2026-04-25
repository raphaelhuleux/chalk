import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';

export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;
export type HeadingColors = Partial<Record<HeadingLevel, string>>;

interface TokenColorRule {
  scope?: string | string[];
  settings?: { foreground?: string };
}

interface ThemeJson {
  include?: string;
  tokenColors?: TokenColorRule[];
}

/**
 * Best-effort extraction of the active theme's markdown heading colors.
 * Returns an empty object when the theme is built-in (Dark+/Light+ are
 * not addressable on disk), uses `include:` (not followed), or has no
 * matching rules. Callers should provide CSS-var fallbacks.
 */
export function getMarkdownHeadingColors(): HeadingColors {
  const themeName = vscode.workspace
    .getConfiguration('workbench')
    .get<string>('colorTheme');
  if (!themeName) return {};

  const themePath = findThemePath(themeName);
  if (!themePath) return {};

  const theme = loadThemeJson(themePath);
  if (!theme?.tokenColors) return {};

  const result: HeadingColors = {};
  for (const level of [1, 2, 3, 4, 5, 6] as const) {
    const color = findHeadingColor(theme.tokenColors, level);
    if (color) result[level] = color;
  }
  return result;
}

function findThemePath(themeLabel: string): string | null {
  for (const ext of vscode.extensions.all) {
    const themes = ext.packageJSON?.contributes?.themes as
      | Array<{ label?: string; id?: string; path: string }>
      | undefined;
    if (!Array.isArray(themes)) continue;
    for (const theme of themes) {
      if (theme.label === themeLabel || theme.id === themeLabel) {
        return path.join(ext.extensionPath, theme.path);
      }
    }
  }
  return null;
}

function loadThemeJson(themePath: string): ThemeJson | null {
  try {
    const raw = fs.readFileSync(themePath, 'utf8');
    const stripped = raw
      .replace(/\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '');
    return JSON.parse(stripped) as ThemeJson;
  } catch {
    return null;
  }
}

function findHeadingColor(
  rules: TokenColorRule[],
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
