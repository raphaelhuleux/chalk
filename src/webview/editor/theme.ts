import { EditorView } from '@codemirror/view';
import { Compartment, Extension, Prec } from '@codemirror/state';

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
 * Forcibly suppress the browser's native ::selection inside the webview.
 *
 * Background: in a VS Code custom-editor webview, VS Code injects its own
 * stylesheet AFTER our static editor.css loads, and that stylesheet can
 * win over scoped + !important rules via equal-specificity-later-declared.
 * The result: macOS's active ::selection (opaque colors, white text)
 * paints on top of CM6's layered selection while the editor is focused,
 * making text unreadable. When focus leaves, the browser hides the active
 * ::selection and the layered version becomes visible — which is why the
 * bug is focus-conditional.
 *
 * Fix: inject the transparenting rule via CM6's `EditorView.theme()` with
 * `Prec.highest`. CM6's StyleModule appends to document.head AFTER any
 * VS Code injection, and our Prec.highest puts us above CM6's own base
 * theme rules too. This is the "Override Of Last Resort" — placing the
 * rule in CM6's managed stylesheet, where the framework controls cascade
 * order, is the only way to win against later environment injections.
 *
 * Both background-color AND color must override: macOS's active
 * ::selection also forces `color: white` on selected text. Without
 * overriding `color`, even a transparent background leaves white-on-white
 * text once CM6's layered selection paints behind it.
 */
function suppressNativeSelection(): Extension {
  // Flat selectors (no nested commas) — CM6's StyleModule expander has
  // trouble with comma-cross-product nesting and was emitting garbled
  // CSS for the previous `'&, & *': { '&::selection, & ::selection' }`
  // form. Only `background` is overridden, NOT `color` — explicitly
  // setting color on ::selection in CM6 can cause oddities since the
  // text layer is positioned independently from the selection layer.
  return Prec.highest(
    EditorView.theme({
      '&::selection': { background: 'transparent !important' },
      '& ::selection': { background: 'transparent !important' },
      '&.cm-focused::selection': { background: 'transparent !important' },
      '&.cm-focused ::selection': { background: 'transparent !important' },
      '&.cm-focused .cm-content::selection': { background: 'transparent !important' },
      '&.cm-focused .cm-content ::selection': { background: 'transparent !important' },
      '&.cm-focused .cm-line::selection': { background: 'transparent !important' },
      '&.cm-focused .cm-line ::selection': { background: 'transparent !important' },
    }),
  );
}

/**
 * CM6 theme that inherits colors, font, and sizing from VS Code's theme
 * via CSS custom properties injected by VS Code into every webview.
 */
export function vsCodeTheme(): Extension {
  return [
    suppressNativeSelection(),
    EditorView.theme({
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
    // Layered selection (drawn behind text in z-index:-1).
    // `opacity` is more reliably supported than `color-mix()` across
    // the webview's Chromium versions, and forces semi-transparency
    // even if the user's theme exports an opaque
    // editor.selectionBackground (some Catppuccin variants do — no
    // alpha channel in the resolved hex). Opacity on the selection
    // div is safe — the div is empty and sits behind text, so the
    // alpha only affects its colored rectangle, not the text glyphs.
    '.cm-selectionBackground, &.cm-focused .cm-selectionBackground': {
      backgroundColor: 'var(--vscode-editor-selectionBackground)',
      opacity: '0.35',
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

    // ── Autocomplete popup ──
    // CM6's tooltip defaults to a light-mode background (we don't pass
    // `{dark: true}` to EditorView.theme, and we don't want to — the
    // VS Code theme can be light, dark, or high-contrast, and the
    // --vscode-editorSuggestWidget-* vars already flip per theme).
    // Overriding the tooltip classes with those vars is the path that
    // tracks the user's chosen theme without our code knowing which
    // one is active.
    '.cm-tooltip': {
      backgroundColor: 'var(--vscode-editorSuggestWidget-background)',
      color: 'var(--vscode-editorSuggestWidget-foreground)',
      border: '1px solid var(--vscode-editorSuggestWidget-border, var(--vscode-widget-border, transparent))',
      borderRadius: '3px',
      fontFamily: 'var(--vscode-font-family)',
      fontSize: 'var(--vscode-font-size)',
      boxShadow: '0 2px 8px var(--vscode-widget-shadow, rgba(0, 0, 0, 0.36))',
    },
    '.cm-tooltip.cm-tooltip-autocomplete > ul': {
      fontFamily: 'var(--vscode-font-family)',
      maxHeight: '20em',
      // CM6's default <ul> has a small top/bottom padding that combines
      // poorly with our row backgrounds — drop it so the selection bar
      // runs edge-to-edge.
      padding: '2px 0',
    },
    '.cm-tooltip.cm-tooltip-autocomplete > ul > li': {
      padding: '2px 6px',
      color: 'var(--vscode-editorSuggestWidget-foreground)',
      lineHeight: '1.5',
    },
    '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected]': {
      backgroundColor: 'var(--vscode-editorSuggestWidget-selectedBackground, var(--vscode-list-activeSelectionBackground))',
      color: 'var(--vscode-editorSuggestWidget-selectedForeground, var(--vscode-list-activeSelectionForeground))',
    },
    '.cm-completionMatchedText': {
      // VS Code uses a distinct accent color (often blue) for the
      // matched chars; underline is too noisy when ranges are short.
      color: 'var(--vscode-editorSuggestWidget-highlightForeground)',
      textDecoration: 'none',
      fontWeight: 'bold',
    },
    '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected] .cm-completionMatchedText': {
      color: 'var(--vscode-editorSuggestWidget-focusHighlightForeground, var(--vscode-editorSuggestWidget-highlightForeground))',
    },
    '.cm-completionDetail': {
      color: 'var(--vscode-descriptionForeground)',
      fontStyle: 'normal',
      marginLeft: '0.6em',
      opacity: '0.85',
    },
    '.cm-completionIcon': {
      color: 'var(--vscode-symbolIcon-keywordForeground, var(--vscode-editorSuggestWidget-foreground))',
      opacity: '0.85',
      width: '1em',
      marginRight: '0.4em',
    },
    }),
  ];
}
