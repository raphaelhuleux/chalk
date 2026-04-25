import { EditorView } from '@codemirror/view';
import { Compartment, Extension } from '@codemirror/state';

/**
 * Preview compartment — wraps live-preview + math plugins for markdown so
 * they can be toggled off at runtime to reveal raw markdown ("source mode").
 * Tex doesn't use this — math is always on; use VS Code's Reopen With →
 * Text Editor to see raw LaTeX. The compartment is exported anyway so
 * setup.ts can wrap md plugins in it.
 */
export const previewCompartment = new Compartment();

/**
 * Theme compartment — kept for future runtime theme swaps.
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
    // CM6 draws a 1px dotted outline on the editor when focused (a11y
    // default). The webview already takes the full viewport, the cursor
    // blink indicates focus, and VS Code's panel-focus ring lives one
    // level up — so the inner outline is redundant and visually noisy.
    '&.cm-focused': {
      outline: 'none',
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
