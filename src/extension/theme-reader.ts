import * as vscode from 'vscode';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';

/**
 * Colors we inject into the webview, keyed by the CM6 HighlightStyle tag
 * they should drive. Each field is a CSS color string ready for
 * `color: …` (typically a hex like `#569cd6`).
 */
export interface ThemeColors {
  keyword: string | null;
  tagName: string | null;
  comment: string | null;
  number: string | null;
  atom: string | null;
  bracket: string | null;
  specialVariable: string | null;
  invalid: string | null;
}

/**
 * For each CM5 token type the stex mode emits, an ordered list of
 * TextMate scopes to try against the theme's `tokenColors`. Most
 * specific first. The first hit wins.
 *
 * These scopes are tuned to what LaTeX grammars (Workshop's and
 * VS Code's built-in LaTeX mode) typically emit. Adjust if a popular
 * theme consistently produces the wrong color for a given token.
 */
const SCOPE_CANDIDATES: Record<keyof ThemeColors, string[]> = {
  // \documentclass, \section, \begin, … (stex tokenizes all commands
  // as a single "keyword" category, so we pick whichever generic scope
  // the theme styles most meaningfully).
  keyword: [
    'support.function.be.latex',
    'keyword.control.preamble.latex',
    'support.function.general.latex',
    'keyword.control.latex',
    'support.function.latex',
    'entity.name.function.latex',
    'keyword.control',
    'support.function',
    'entity.name.function',
    'keyword',
  ],
  // Environment and label names inside \begin{…}, \label{…}.
  tagName: [
    'entity.name.function.environment.latex',
    'support.class.latex',
    'entity.name.type.environment.latex',
    'entity.name.function.latex',
    'entity.name.type.latex',
    'entity.name.type',
    'support.class',
    'entity.name.tag',
    'entity.name',
    'variable.parameter',
  ],
  comment: [
    'comment.line.percentage.latex',
    'comment.line.percentage',
    'comment.line',
    'comment',
  ],
  number: [
    'constant.numeric.latex',
    'constant.numeric',
    'constant',
  ],
  atom: [
    'constant.character.latex',
    'constant.character',
    'constant.language',
    'constant.other',
    'constant',
  ],
  bracket: [
    'punctuation.definition.arguments.begin.latex',
    'punctuation.definition.arguments',
    'punctuation.definition',
    'punctuation.section',
    'punctuation',
  ],
  specialVariable: [
    'variable.parameter.function.latex',
    'variable.parameter.latex',
    'variable.parameter',
    'variable.other',
    'variable',
  ],
  invalid: ['invalid.illegal', 'invalid.deprecated', 'invalid'],
};

interface RawTokenColor {
  scope?: string | string[];
  settings?: { foreground?: string; fontStyle?: string };
}

interface RawTheme {
  include?: string;
  tokenColors?: RawTokenColor[];
  colors?: Record<string, string>;
}

/**
 * Entry point. Reads the active theme, resolves token colors for our
 * CM6 tag set, returns null if any step fails (caller falls back to
 * the hex defaults baked into the HighlightStyle).
 */
export async function readThemeColors(): Promise<ThemeColors | null> {
  const diag = await diagnoseThemeResolution();
  return diag.colors;
}

/**
 * Same work as `readThemeColors`, but also returns the intermediate
 * values useful for debugging a mismatch: theme label, resolved file
 * path, raw token-color count, and per-field which candidate scope
 * actually matched. Surfaced via the `chalk.diagnoseTheme` command.
 */
export interface ThemeDiagnostics {
  themeLabel: string | null;
  themePath: string | null;
  tokenColorCount: number;
  colors: ThemeColors | null;
  matchedScopes: Partial<Record<keyof ThemeColors, string | null>>;
  error?: string;
}

export async function diagnoseThemeResolution(): Promise<ThemeDiagnostics> {
  const diag: ThemeDiagnostics = {
    themeLabel: null,
    themePath: null,
    tokenColorCount: 0,
    colors: null,
    matchedScopes: {},
  };
  try {
    diag.themeLabel =
      vscode.workspace.getConfiguration('workbench').get<string>('colorTheme') ??
      null;
    if (!diag.themeLabel) return diag;

    diag.themePath = findThemeFilePath(diag.themeLabel);
    if (!diag.themePath) return diag;

    const tokens = await loadMergedTokenColors(diag.themePath);
    diag.tokenColorCount = tokens.length;
    const { colors, matched } = resolveAllWithProvenance(tokens);
    diag.colors = colors;
    diag.matchedScopes = matched;
    return diag;
  } catch (e) {
    diag.error = e instanceof Error ? e.message : String(e);
    return diag;
  }
}

/**
 * Find the filesystem path of the active theme's JSON definition by
 * iterating all installed extensions' `contributes.themes` entries.
 */
function findThemeFilePath(themeLabel: string): string | null {
  for (const ext of vscode.extensions.all) {
    const themes = ext.packageJSON?.contributes?.themes as
      | { label: string; id?: string; path: string }[]
      | undefined;
    if (!themes) continue;
    for (const t of themes) {
      if (t.label === themeLabel || t.id === themeLabel) {
        return path.join(ext.extensionPath, t.path);
      }
    }
  }
  return null;
}

/**
 * Load a theme file + recursively resolve its `include` chain, merging
 * tokenColors with later entries overriding earlier ones (CSS-style
 * cascade). Depth-capped at 4 to avoid pathological loops.
 */
async function loadMergedTokenColors(
  themePath: string,
  depth = 0,
): Promise<RawTokenColor[]> {
  if (depth > 4) return [];
  const raw = await readThemeFile(themePath);
  if (!raw) return [];

  let merged: RawTokenColor[] = [];
  if (raw.include) {
    const includePath = path.resolve(path.dirname(themePath), raw.include);
    merged = await loadMergedTokenColors(includePath, depth + 1);
  }
  if (raw.tokenColors) {
    merged = merged.concat(raw.tokenColors);
  }
  return merged;
}

/**
 * Read a theme JSON file. Tolerates JSONC (line comments, trailing
 * commas) by stripping them before parsing.
 */
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

/** Minimal JSONC → JSON: strip `//` line comments and trailing commas. */
function stripJsonc(text: string): string {
  return text
    .replace(/^\s*\/\/.*$/gm, '')
    .replace(/,(\s*[}\]])/g, '$1');
}

/**
 * For every field in ThemeColors, walk its candidate scope list and
 * return the first color the theme matches. Also records which scope
 * produced the match (useful for diagnostics).
 */
function resolveAllWithProvenance(tokens: RawTokenColor[]): {
  colors: ThemeColors;
  matched: Partial<Record<keyof ThemeColors, string | null>>;
} {
  const colors: Partial<ThemeColors> = {};
  const matched: Partial<Record<keyof ThemeColors, string | null>> = {};
  for (const key of Object.keys(SCOPE_CANDIDATES) as (keyof ThemeColors)[]) {
    colors[key] = null;
    matched[key] = null;
    for (const scope of SCOPE_CANDIDATES[key]) {
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
 * Find the color that would apply to `targetScope` in the given
 * tokenColors array.
 *
 * Matching rules (simplified TextMate):
 *   - An entry matches if any of its `scope` strings is a dot-separated
 *     prefix of the target (segments must align on dots).
 *   - Among matches, the LONGEST prefix wins.
 *   - Ties go to the LATER entry (cascade).
 */
export function resolveScopeColor(
  targetScope: string,
  tokens: RawTokenColor[],
): string | null {
  let bestColor: string | null = null;
  let bestScore = -1;
  const targetSegments = targetScope.split('.');

  tokens.forEach((t, index) => {
    const scopes = normalizeScopes(t.scope);
    const foreground = t.settings?.foreground;
    if (!foreground) return;
    for (const s of scopes) {
      const score = prefixScore(s, targetSegments);
      // `>=` so later entries with the same score take precedence.
      if (score >= 0 && score >= bestScore) {
        bestScore = score;
        bestColor = foreground;
      }
    }
    void index;
  });

  return bestColor;
}

function normalizeScopes(scope: string | string[] | undefined): string[] {
  if (!scope) return [];
  if (typeof scope === 'string') {
    return scope.split(',').map((s) => s.trim()).filter(Boolean);
  }
  return scope.map((s) => s.trim()).filter(Boolean);
}

/**
 * Score how specifically `sourceScope` matches a target whose segments
 * are `targetSegments`. Segments of sourceScope must equal the leading
 * segments of the target. Returns the number of matched segments, or
 * -1 if no match.
 */
function prefixScore(sourceScope: string, targetSegments: string[]): number {
  const sourceSegments = sourceScope.split('.');
  if (sourceSegments.length > targetSegments.length) return -1;
  for (let i = 0; i < sourceSegments.length; i++) {
    if (sourceSegments[i] !== targetSegments[i]) return -1;
  }
  return sourceSegments.length;
}
