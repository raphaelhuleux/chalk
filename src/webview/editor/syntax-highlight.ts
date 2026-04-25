import { HighlightStyle } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

/**
 * Syntax highlighting for LaTeX. The `stex` stream language emits
 * CM5-style token strings ("keyword", "tag", "comment", etc.) which
 * `@codemirror/language`'s `StreamLanguage` adapter maps automatically
 * to `@lezer/highlight` tags. We only style the tags here.
 *
 * Colors come from CSS custom properties (`--chalk-syntax-*`) that
 * the extension host sets by reading the active VS Code theme's JSON
 * `tokenColors` and posting them to the webview (see
 * [src/extension/theme-reader.ts]). When that pipeline can't find a
 * color (theme file missing, parse error, scope not matched) the hex
 * fallbacks baked into each `var(..., #hex)` kick in — Dark+ flavored,
 * so light themes may look slightly off only in the fallback case.
 */
export const texHighlightStyle = HighlightStyle.define([
  // \documentclass, \section, \begin, …
  { tag: t.keyword, color: 'var(--chalk-syntax-keyword, #569cd6)' },

  // Environment names and labels inside \begin{…}, \label{…}
  { tag: t.tagName, color: 'var(--chalk-syntax-tag, #4ec9b0)' },

  // %-line comments
  {
    tag: t.comment,
    color: 'var(--chalk-syntax-comment, #6a9955)',
    fontStyle: 'italic',
  },

  { tag: t.number, color: 'var(--chalk-syntax-number, #b5cea8)' },

  { tag: t.atom, color: 'var(--chalk-syntax-atom, #c586c0)' },

  // { } [ ]
  {
    tag: t.bracket,
    color: 'var(--chalk-syntax-bracket, var(--vscode-editor-foreground))',
  },

  // stex emits "variableName.special" for a small set of tokens
  {
    tag: t.special(t.variableName),
    color: 'var(--chalk-syntax-special-variable, #dcdcaa)',
  },

  // Malformed constructs flagged by stex
  {
    tag: t.invalid,
    color: 'var(--chalk-syntax-invalid, var(--vscode-errorForeground, #f48771))',
    textDecoration: 'underline wavy',
  },
]);
