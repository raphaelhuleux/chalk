import * as vscode from 'vscode';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import type { ThemeColors as EditorThemeColors } from '@chalk/editor-core';

/**
 * editor-core's `ThemeColors` (the `theme-colors` payload), required because
 * the reader fills every field (null where the theme has no match).
 */
export type ThemeColors = Required<EditorThemeColors>;

type ScopeCandidates = Record<keyof ThemeColors, string[]>;

export interface RawTokenColor {
  scope?: string | string[];
  settings?: { foreground?: string; fontStyle?: string };
}

interface RawTheme {
  include?: string;
  tokenColors?: RawTokenColor[];
  colors?: Record<string, string>;
}

/**
 * Resolve the active theme's token colors for our tag set; null on failure
 * (the editor keeps its default colors).
 */
export async function readThemeColors(
  scopes: ScopeCandidates,
): Promise<ThemeColors | null> {
  const diag = await diagnoseThemeResolution(scopes);
  return diag.colors;
}

/**
 * `readThemeColors` plus intermediate values for debugging a mismatch.
 * Surfaced via the `chalk.diagnoseTheme` command.
 */
export interface ThemeDiagnostics {
  themeLabel: string | null;
  themePath: string | null;
  tokenColorCount: number;
  colors: ThemeColors | null;
  matchedScopes: Partial<Record<keyof ThemeColors, string | null>>;
  error?: string;
}

export async function diagnoseThemeResolution(
  scopes: ScopeCandidates,
): Promise<ThemeDiagnostics> {
  const diag: ThemeDiagnostics = {
    themeLabel: null,
    themePath: null,
    tokenColorCount: 0,
    colors: null,
    matchedScopes: {},
  };
  try {
    const theme = await loadActiveTheme();
    diag.themeLabel = theme.label;
    diag.themePath = theme.path;
    if (!theme.path) return diag;

    const tokens = theme.tokens;
    diag.tokenColorCount = tokens.length;
    const { colors, matched } = resolveAllWithProvenance(tokens, scopes);
    diag.colors = colors;
    diag.matchedScopes = matched;
    return diag;
  } catch (e) {
    diag.error = e instanceof Error ? e.message : String(e);
    return diag;
  }
}

let cachedTheme: { key: string; tokens: Promise<RawTokenColor[]> } | null = null;

/**
 * The active theme's label, file and merged tokenColors, cached once per
 * theme: each panel reads it twice per push and a theme switch pushes twice.
 * Keyed by label and file; an empty result is not kept (it may be a failed
 * read).
 */
export async function loadActiveTheme(): Promise<{
  label: string | null;
  path: string | null;
  tokens: RawTokenColor[];
}> {
  const label = activeThemeLabel();
  const themePath = label ? findThemeFilePath(label) : null;
  if (!label || !themePath) return { label, path: themePath, tokens: [] };

  const key = `${label}\0${themePath}`;
  if (cachedTheme?.key !== key) {
    cachedTheme = { key, tokens: loadMergedTokenColors(themePath) };
  }
  const entry = cachedTheme;
  const tokens = await entry.tokens;
  if (tokens.length === 0 && cachedTheme === entry) cachedTheme = null;
  return { label, path: themePath, tokens };
}

/**
 * The label (or id) of the theme VS Code is showing. `workbench.colorTheme`
 * goes stale when VS Code follows the OS; this mirrors VS Code's
 * getColorThemeSettingId (high-contrast auto-detect, then
 * autoDetectColorScheme, then colorTheme). The API exposes only the active
 * theme's kind, not the OS state, so the kind stands in for it; a
 * high-contrast colorTheme of the matching kind wins.
 */
export function activeThemeLabel(): string | null {
  const workbench = vscode.workspace.getConfiguration('workbench');
  const windowConfig = vscode.workspace.getConfiguration('window');
  const configured = workbench.get<string>('colorTheme') || null;
  const { Light, HighContrast, HighContrastLight } = vscode.ColorThemeKind;
  const kind = vscode.window.activeColorTheme.kind;
  const followsScheme = windowConfig.get<boolean>('autoDetectColorScheme') === true;

  let preferred: string | null = null;
  if (
    (kind === HighContrast || kind === HighContrastLight) &&
    windowConfig.get<boolean>('autoDetectHighContrast') === true &&
    (followsScheme || !configured || findTheme(configured)?.kind !== kind)
  ) {
    preferred =
      kind === HighContrast
        ? 'preferredHighContrastColorTheme'
        : 'preferredHighContrastLightColorTheme';
  } else if (followsScheme) {
    preferred =
      kind === Light || kind === HighContrastLight
        ? 'preferredLightColorTheme'
        : 'preferredDarkColorTheme';
  }
  return (preferred && workbench.get<string>(preferred)) || configured;
}

/** The theme's JSON path, from installed extensions' `contributes.themes`. */
export function findThemeFilePath(themeLabel: string): string | null {
  return findTheme(themeLabel)?.path ?? null;
}

/** A contributed theme's file and, from its `uiTheme`, its kind. */
function findTheme(
  themeLabel: string,
): { path: string; kind: vscode.ColorThemeKind | undefined } | null {
  for (const ext of vscode.extensions.all) {
    const themes = ext.packageJSON?.contributes?.themes as
      | { label: string; id?: string; path: string; uiTheme?: string }[]
      | undefined;
    if (!themes) continue;
    for (const t of themes) {
      if (t.label === themeLabel || t.id === themeLabel) {
        const kinds: Record<string, vscode.ColorThemeKind> = {
          vs: vscode.ColorThemeKind.Light,
          'vs-dark': vscode.ColorThemeKind.Dark,
          'hc-black': vscode.ColorThemeKind.HighContrast,
          'hc-light': vscode.ColorThemeKind.HighContrastLight,
        };
        return {
          path: path.join(ext.extensionPath, t.path),
          kind: t.uiTheme ? kinds[t.uiTheme] : undefined,
        };
      }
    }
  }
  return null;
}

/**
 * Load a theme and its `include` chain, later tokenColors overriding earlier
 * ones. Depth-capped, and visited paths short-circuit include cycles.
 */
export async function loadMergedTokenColors(
  themePath: string,
  depth = 0,
  visited: Set<string> = new Set(),
): Promise<RawTokenColor[]> {
  if (depth > 4) return [];
  const absPath = path.resolve(themePath);
  if (visited.has(absPath)) return [];
  visited.add(absPath);

  const raw = await readThemeFile(absPath);
  if (!raw) return [];

  let merged: RawTokenColor[] = [];
  if (raw.include) {
    const includePath = path.resolve(path.dirname(absPath), raw.include);
    merged = await loadMergedTokenColors(includePath, depth + 1, visited);
  }
  if (raw.tokenColors) {
    merged = merged.concat(raw.tokenColors);
  }
  return merged;
}

/** Read a theme JSON file, falling back to a minimal JSONC strip. */
async function readThemeFile(filePath: string): Promise<RawTheme | null> {
  try {
    const text = await fs.readFile(filePath, 'utf8');
    try {
      return JSON.parse(text) as RawTheme;
    } catch {
      return JSON.parse(stripJsonc(text)) as RawTheme;
    }
  } catch {
    return null;
  }
}

/** Minimal JSONC → JSON: strip whole-line `//` comments and trailing commas. */
function stripJsonc(text: string): string {
  return text
    .replace(/^\s*\/\/.*$/gm, '')
    .replace(/,(\s*[}\]])/g, '$1');
}

/** Per field, the first candidate scope the theme colors, and which one. */
function resolveAllWithProvenance(
  tokens: RawTokenColor[],
  scopes: ScopeCandidates,
): {
  colors: ThemeColors;
  matched: Partial<Record<keyof ThemeColors, string | null>>;
} {
  const colors: Partial<ThemeColors> = {};
  const matched: Partial<Record<keyof ThemeColors, string | null>> = {};
  for (const key of Object.keys(scopes) as (keyof ThemeColors)[]) {
    colors[key] = null;
    matched[key] = null;
    for (const scope of scopes[key]) {
      const color = resolveScopeColor(scope, tokens);
      if (color) {
        colors[key] = color;
        matched[key] = scope;
        break;
      }
    }
  }
  return { colors: colors as ThemeColors, matched };
}

/**
 * The color for `targetScope`, simplified TextMate: a scope matches as a
 * dot-aligned prefix, the longest prefix wins, ties go to the later entry.
 */
export function resolveScopeColor(
  targetScope: string,
  tokens: RawTokenColor[],
): string | null {
  let bestColor: string | null = null;
  let bestScore = -1;
  const targetSegments = targetScope.split('.');

  for (const t of tokens) {
    const scopes = normalizeScopes(t.scope);
    const foreground = t.settings?.foreground;
    if (!foreground) continue;
    for (const s of scopes) {
      const score = prefixScore(s, targetSegments);
      // `>=` so later entries with the same score take precedence.
      if (score >= 0 && score >= bestScore) {
        bestScore = score;
        bestColor = foreground;
      }
    }
  }

  return bestColor;
}

function normalizeScopes(scope: string | string[] | undefined): string[] {
  if (!scope) return [];
  if (typeof scope === 'string') {
    return scope.split(',').map((s) => s.trim()).filter(Boolean);
  }
  return scope.map((s) => s.trim()).filter(Boolean);
}

/** Matched leading segment count, or -1 if `sourceScope` isn't a prefix. */
function prefixScore(sourceScope: string, targetSegments: string[]): number {
  const sourceSegments = sourceScope.split('.');
  if (sourceSegments.length > targetSegments.length) return -1;
  for (let i = 0; i < sourceSegments.length; i++) {
    if (sourceSegments[i] !== targetSegments[i]) return -1;
  }
  return sourceSegments.length;
}
