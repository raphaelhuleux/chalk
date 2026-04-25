import { EditorView } from '@codemirror/view';
import { Compartment, Extension } from '@codemirror/state';

/**
 * Theme compartment — kept for future runtime theme swaps, even though
 * the current mapping derives entirely from VS Code CSS variables and
 * does not need to switch. No preview compartment: the math plugin is
 * always on in chalk-tex (use VS Code's Reopen With → Text Editor to see
 * raw LaTeX).
 */
export const themeCompartment = new Compartment();

/**
 * CM6 theme that inherits colors, font, and sizing from VS Code's theme
 * via CSS custom properties injected by VS Code into every webview.
 */
export function vsCodeTheme(): Extension {
  return EditorView.theme({
    '&': {
      color: 'var(--vscode-editor-foreground)',
      backgroundColor: 'var(--vscode-editor-background)',
      fontFamily: 'var(--vscode-editor-font-family)',
      fontSize: 'var(--vscode-editor-font-size)',
    },
    '.cm-content': {
      caretColor: 'var(--vscode-editorCursor-foreground)',
      fontFamily: 'var(--vscode-editor-font-family)',
    },
    '.cm-line': {
      lineHeight: '1.5',
    },
    '&.cm-focused .cm-cursor': {
      borderLeftColor: 'var(--vscode-editorCursor-foreground)',
    },
    // CM6's drawSelection() extension renders selection as absolutely-
    // positioned divs in a z-index:-1 layer, always behind the text.
    // We only need to recolor those divs — do NOT target `::selection`
    // here. CM6 deliberately transparents the browser's native
    // ::selection (via a Prec.highest rule) so the layered version is
    // the only one you see. Re-enabling ::selection would paint an
    // opaque overlay on top of text.
    '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': {
      backgroundColor: 'var(--vscode-editor-selectionBackground)',
    },
    '.cm-activeLine': {
      backgroundColor: 'var(--vscode-editor-lineHighlightBackground)',
    },
    '.cm-gutters': {
      backgroundColor: 'var(--vscode-editorGutter-background)',
      color: 'var(--vscode-editorLineNumber-foreground)',
      border: 'none',
    },
    '.cm-placeholder': {
      color: 'var(--vscode-editorHint-foreground)',
      fontStyle: 'italic',
    },
  });
}
