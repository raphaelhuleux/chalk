import { HighlightStyle } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

/**
 * Tag colors for the `stex` stream language. The `--chalk-syntax-*` variables
 * are set by mount.ts from the host's `theme-colors` message; the Dark+ hex
 * fallbacks apply only when the host sends none.
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
