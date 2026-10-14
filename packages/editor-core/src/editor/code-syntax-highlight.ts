import { HighlightStyle } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

/**
 * Highlighting for fenced code blocks. Like `texHighlightStyle`, colors come
 * from host-injected `--chalk-syntax-*` properties with Dark+ fallbacks. Only
 * code-facing tags, so registering it unscoped in markdown can't restyle prose.
 */
export const codeHighlightStyle = HighlightStyle.define([
  { tag: t.keyword, color: 'var(--chalk-syntax-keyword, #569cd6)' },

  {
    tag: t.comment,
    color: 'var(--chalk-syntax-comment, #6a9955)',
    fontStyle: 'italic',
  },

  { tag: t.string, color: 'var(--chalk-syntax-string, #ce9178)' },

  { tag: t.number, color: 'var(--chalk-syntax-number, #b5cea8)' },

  // True/False/None, NA/NULL, builtins the modes tag as atoms
  { tag: t.atom, color: 'var(--chalk-syntax-atom, #c586c0)' },
  { tag: t.bool, color: 'var(--chalk-syntax-atom, #c586c0)' },

  {
    tag: t.bracket,
    color: 'var(--chalk-syntax-bracket, var(--vscode-editor-foreground))',
  },

  { tag: t.operator, color: 'var(--chalk-syntax-operator, #d4d4d4)' },

  { tag: t.variableName, color: 'var(--chalk-syntax-variable, #9cdcfe)' },
  {
    tag: t.definition(t.variableName),
    color: 'var(--chalk-syntax-special-variable, #dcdcaa)',
  },

  {
    tag: t.invalid,
    color: 'var(--chalk-syntax-invalid, var(--vscode-errorForeground, #f48771))',
    textDecoration: 'underline wavy',
  },
]);
