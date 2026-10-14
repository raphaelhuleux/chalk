import {
  EditorView,
  lineNumbers,
  highlightActiveLineGutter,
} from '@codemirror/view';
import { Compartment, Extension, Prec } from '@codemirror/state';

/**
 * `typewriter` centers the caret line; `focus` dims all but the current
 * sentence; `zen` is host-only chrome hiding, accepted so hosts can send their
 * mode verbatim, and maps to no editor extension.
 */
export type EditingMode = 'normal' | 'zen' | 'typewriter' | 'focus';

/**
 * How much source is concealed: `preview` hides syntax (revealed under the
 * caret), `mixed` renders only math, images and tables, `source` renders
 * nothing. Hosts send the default; Cmd+: cycles the per-editor value
 * (view-mode.ts) in this order.
 */
export type ViewMode = 'preview' | 'mixed' | 'source';
export const VIEW_MODES: readonly ViewMode[] = ['preview', 'mixed', 'source'];

export function nextViewMode(mode: ViewMode): ViewMode {
  return VIEW_MODES[(VIEW_MODES.indexOf(mode) + 1) % VIEW_MODES.length];
}

/**
 * VS Code text-editor settings with a visible CM6 counterpart, read
 * language-scoped by the host. Font and colors are not here: they arrive via
 * the `--vscode-*` CSS variables.
 */
export interface EditorConfig {
  editingMode: EditingMode;
  /** The view mode every editor opens in. */
  viewMode: ViewMode;
  wordWrap: 'off' | 'on' | 'bounded' | 'wordWrapColumn';
  wordWrapColumn: number;
  /** 0 = VS Code default (thin); any positive value is px. */
  cursorWidth: number;
  cursorBlinking: 'blink' | 'smooth' | 'phase' | 'expand' | 'solid';
  lineNumbers: 'on' | 'off' | 'relative' | 'interval';
  /** From `editor.scrollbar.vertical`. */
  scrollbarVertical: 'auto' | 'visible' | 'hidden';
  /** Markdown Preview as styled source ('source', default) or as a typeset
   *  page ('typeset': lists and quotes laid out by depth in em, so they align
   *  in a proportional font; md-typeset.ts). The native LaTeX theme sends
   *  'typeset'. */
  markdownStyle: 'source' | 'typeset';
}

/** Defaults before any config arrives. `wordWrap: 'on'` (not VS Code's 'off')
 *  keeps wrapping if a host never sends a config; `lineNumbers: 'off'` because
 *  the native host never sends it. */
export const defaultEditorConfig: EditorConfig = {
  editingMode: 'normal',
  viewMode: 'preview',
  wordWrap: 'on',
  wordWrapColumn: 80,
  cursorWidth: 0,
  cursorBlinking: 'blink',
  lineNumbers: 'off',
  scrollbarVertical: 'auto',
  markdownStyle: 'source',
};

/**
 * Coerce a host payload into a valid EditorConfig, falling back per field so
 * one malformed field can't fail the whole editor.
 */
export function sanitizeEditorConfig(raw: unknown): EditorConfig {
  const r = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<
    string,
    unknown
  >;
  const oneOf = <T extends string>(
    value: unknown,
    allowed: readonly T[],
    fallback: T,
  ): T =>
    typeof value === 'string' && (allowed as readonly string[]).includes(value)
      ? (value as T)
      : fallback;
  const num = (value: unknown, fallback: number, min: number, max: number): number =>
    typeof value === 'number' && Number.isFinite(value)
      ? Math.min(max, Math.max(min, value))
      : fallback;
  return {
    editingMode: oneOf(
      r.editingMode,
      ['normal', 'zen', 'typewriter', 'focus'],
      defaultEditorConfig.editingMode,
    ),
    viewMode: oneOf(r.viewMode, VIEW_MODES, defaultEditorConfig.viewMode),
    wordWrap: oneOf(
      r.wordWrap,
      ['off', 'on', 'bounded', 'wordWrapColumn'],
      defaultEditorConfig.wordWrap,
    ),
    wordWrapColumn: num(r.wordWrapColumn, defaultEditorConfig.wordWrapColumn, 1, 400),
    cursorWidth: num(r.cursorWidth, defaultEditorConfig.cursorWidth, 0, 25),
    cursorBlinking: oneOf(
      r.cursorBlinking,
      ['blink', 'smooth', 'phase', 'expand', 'solid'],
      defaultEditorConfig.cursorBlinking,
    ),
    lineNumbers: oneOf(
      r.lineNumbers,
      ['on', 'off', 'relative', 'interval'],
      defaultEditorConfig.lineNumbers,
    ),
    scrollbarVertical: oneOf(
      r.scrollbarVertical,
      ['auto', 'visible', 'hidden'],
      defaultEditorConfig.scrollbarVertical,
    ),
    markdownStyle: oneOf(r.markdownStyle, ['source', 'typeset'], defaultEditorConfig.markdownStyle),
  };
}

/** Holds the live-preview and math plugins; view-mode.ts reconfigures it. */
export const previewCompartment = new Compartment();

/** Holds `vsCodeTheme(config)`; mount.ts reconfigures it on `editor-config`. */
export const themeCompartment = new Compartment();

/**
 * Keep native ::selection OFF: CM6's layered selection is the only intended
 * paint, and the native one draws opaque over math widgets and text. VS Code
 * injects its stylesheet after editor.css and can beat our !important rules,
 * so the override lives in CM6's own StyleModule (appended later) at
 * `Prec.highest`.
 */
const nativeSelectionSuppressed: Extension = (() => {
  // Flat selectors: StyleModule garbles comma-nested ones. Only `background`
  // is overridden, not `color`: the text layer is positioned independently of
  // the selection layer.
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
})();

const themeCache = new Map<string, Extension>();

/**
 * CM6 theme from the `--vscode-*` CSS variables plus the EditorConfig-driven
 * pieces. Memoized on the fields it reads: mount.ts compares the returned
 * extension to skip a reconfigure, and style-mod never drops old rules.
 */
export function vsCodeTheme(cfg: EditorConfig = defaultEditorConfig): Extension {
  const key = [
    cfg.wordWrap,
    cfg.wordWrapColumn,
    cfg.cursorWidth,
    cfg.cursorBlinking,
    cfg.lineNumbers,
    cfg.scrollbarVertical,
  ].join('|');
  let theme = themeCache.get(key);
  if (!theme) {
    theme = buildTheme(cfg);
    themeCache.set(key, theme);
  }
  return theme;
}

function buildTheme(cfg: EditorConfig): Extension {
  const bounded = cfg.wordWrap === 'bounded' || cfg.wordWrap === 'wordWrapColumn';

  const contentRule: Record<string, string> = {
    caretColor: 'var(--vscode-editorCursor-foreground)',
    fontFamily: 'var(--vscode-editor-font-family)',
    // Left 2px: line numbers end flush with the text (see .cm-lineNumbers).
    // Right `max()`: an inset on wide panes that never collapses on a narrow split.
    padding: '6px max(1.5rem, 8%) 6px 2px',
  };
  if (bounded) {
    // Bounded wrap breaks at min(viewport, wordWrapColumn). border-box plus
    // the padding in the calc() makes the text area exactly that many `ch`.
    contentRule.padding = '6px 1.5rem 6px 2px';
    contentRule.boxSizing = 'border-box';
    contentRule.maxWidth = `calc(${cfg.wordWrapColumn}ch + 2px + 1.5rem)`;
  }

  const cursorRule: Record<string, string> = {
    borderLeftColor: 'var(--vscode-editorCursor-foreground)',
  };
  if (cfg.cursorWidth > 0) {
    cursorRule.borderLeftWidth = `${cfg.cursorWidth}px`;
  }

  const spec: Record<string, Record<string, string>> = {
    '&': {
      color: 'var(--vscode-editor-foreground)',
      backgroundColor: 'var(--vscode-editor-background)',
      fontFamily: 'var(--vscode-editor-font-family)',
      fontSize: 'var(--vscode-editor-font-size)',
    },
    // CM6's focus outline is redundant: the caret shows focus and the host
    // draws its own pane focus ring.
    '&.cm-focused': {
      outline: 'none',
    },
    '.cm-content': contentRule,
    '.cm-line': {
      lineHeight: '1.5',
    },
    '&.cm-focused .cm-cursor': cursorRule,
  };

  // drawSelection() sets only animation-name and -duration inline, so
  // timing-function and play-state stay themable.
  if (cfg.cursorBlinking === 'smooth' || cfg.cursorBlinking === 'phase') {
    spec['&.cm-focused > .cm-scroller > .cm-cursorLayer'] = {
      animationTimingFunction: 'ease-in-out',
    };
  } else if (cfg.cursorBlinking === 'solid') {
    // Paused at 0% of cm-blink = fully visible, never blinks.
    spec['&.cm-focused > .cm-scroller > .cm-cursorLayer'] = {
      animationPlayState: 'paused',
    };
  }

  if (cfg.scrollbarVertical === 'hidden') {
    spec['.cm-scroller'] = { scrollbarWidth: 'none' };
    spec['.cm-scroller::-webkit-scrollbar'] = { display: 'none' };
  }

  if (cfg.wordWrap !== 'off') {
    // CM6's `break-spaces` lets a row break after an atomic inline box (KaTeX
    // widget, `.cm-widgetBuffer`) and BEFORE the following space, so the next
    // row opens with it. `pre-wrap` hangs the space at the row end instead.
    // Pinned by the "a wrapped row never opens with a space" browser scenarios.
    spec['.cm-lineWrapping'] = { whiteSpace: 'pre-wrap' };
    // Hung spaces put the caret past the column, and `.cm-scroller` would
    // scroll sideways to follow it: clip the layers horizontally. Wrap mode
    // only, since unwrapped lines legitimately put the caret there.
    spec['.cm-scroller > .cm-layer'] = { width: '100%', overflowX: 'clip' };
  }

  return [
    nativeSelectionSuppressed,
    cfg.lineNumbers !== 'off' ? [lineNumbers(), highlightActiveLineGutter()] : [],
    cfg.wordWrap !== 'off' ? EditorView.lineWrapping : [],
    EditorView.theme(spec),
    chromeTheme,
  ];
}

/**
 * Config-independent rules, built once: each `EditorView.theme` call adds a
 * fresh scope class and style-mod never drops rules.
 */
const chromeTheme: Extension = EditorView.theme({
  // Translucency on the LAYER, never the rectangles: CM6 overlaps rectangles
  // on a row a rendered construct splits, and per-rectangle opacity paints the
  // overlap darker. Also tames opaque theme selection colours; a host whose
  // colour is already final sets --chalk-selection-opacity to 1.
  '.cm-selectionLayer': {
    opacity: 'var(--chalk-selection-opacity, 0.35)',
  },
  '.cm-selectionBackground': {
    backgroundColor:
      'var(--vscode-editor-inactiveSelectionBackground, var(--vscode-editor-selectionBackground))',
  },
  // Repeats CM6's base-theme selector exactly: anything less specific loses
  // to its default colour while focused.
  '&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground': {
    backgroundColor: 'var(--vscode-editor-selectionBackground)',
  },
  '.cm-gutters': {
    backgroundColor: 'var(--vscode-editorGutter-background)',
    color: 'var(--vscode-editorLineNumber-foreground)',
    border: 'none',
  },
  // Mirrors the user's VS Code custom CSS (dim 35px numbers flush with the
  // text), not stock VS Code geometry; webviews never receive that CSS.
  '.cm-lineNumbers': {
    opacity: '0.3',
  },
  '.cm-lineNumbers .cm-gutterElement': {
    padding: '0',
    width: '35px',
  },
  // VS Code always brightens the active number but paints no gutter background.
  '.cm-activeLineGutter': {
    backgroundColor: 'transparent',
    color: 'var(--vscode-editorLineNumber-activeForeground)',
  },
  '.cm-placeholder': {
    color: 'var(--vscode-editorHint-foreground)',
    fontStyle: 'italic',
  },

  // ── Autocomplete popup ──
  // No `{dark: true}`: the suggest-widget vars already flip with the theme.
  '.cm-tooltip': {
    backgroundColor: 'var(--vscode-editorSuggestWidget-background)',
    color: 'var(--vscode-editorSuggestWidget-foreground)',
    border: '1px solid var(--vscode-editorSuggestWidget-border, var(--vscode-widget-border, transparent))',
    borderRadius: '11px',
    fontFamily: 'var(--vscode-font-family)',
    fontSize: 'var(--vscode-font-size)',
    // Same shadow as `.chalk-find`: every floating surface is lit alike.
    boxShadow: '0 8px 26px rgba(28, 23, 15, 0.30), 0 1px 4px rgba(28, 23, 15, 0.16)',
  },
  '.cm-tooltip.cm-tooltip-autocomplete': {
    // Keeps the edge rows inside the rounded corners while scrolling.
    overflow: 'hidden',
    padding: '0',
  },
  // Entry animation, gated on Reduce Motion below like the find panel's.
  '@keyframes cm-chalk-complete-in': {
    from: { opacity: '0', transform: 'translateY(-4px)' },
    to: { opacity: '1', transform: 'translateY(0)' },
  },
  '.cm-tooltip.cm-tooltip-autocomplete > ul': {
    // Options use the document's face and size so a row previews the edit.
    // Pinned in Tests/browser/run.mjs against `.cm-content`.
    fontFamily: 'var(--vscode-editor-font-family)',
    fontSize: 'var(--vscode-editor-font-size)',
    maxHeight: 'min(46vh, 20em)',
    minWidth: '14em',
    maxWidth: 'min(34em, 92vw)',
    margin: '0',
    padding: '5px',
    scrollbarWidth: 'thin',
    scrollbarColor: 'var(--vscode-editorLineNumber-foreground, #6b6862) transparent',
    overscrollBehavior: 'contain',
  },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li': {
    display: 'flex',
    alignItems: 'baseline',
    gap: '0.6em',
    padding: '3px 8px',
    borderRadius: '7px',
    lineHeight: '1.45',
    color: 'var(--vscode-editorSuggestWidget-foreground)',
  },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li:hover:not([aria-selected])': {
    backgroundColor:
      'color-mix(in srgb, var(--vscode-editorSuggestWidget-foreground, #e6e2da) 7%, transparent)',
  },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected]': {
    // Caret accent over the theme's own selection colour.
    backgroundColor:
      'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 13%, var(--vscode-editorSuggestWidget-selectedBackground, var(--vscode-list-activeSelectionBackground, #2a2825)))',
    color:
      'var(--vscode-editorSuggestWidget-selectedForeground, var(--vscode-list-activeSelectionForeground))',
  },
  '.cm-completionLabel': {
    // Truncate rather than widen the popup past `max-width`.
    flex: '1 1 auto',
    minWidth: '0',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    whiteSpace: 'nowrap',
  },
  '.cm-completionMatchedText': {
    // Colour, not underline: matches are often one or two characters.
    color: 'var(--vscode-editorSuggestWidget-highlightForeground)',
    textDecoration: 'none',
    fontWeight: '600',
  },
  '.cm-tooltip.cm-tooltip-autocomplete > ul > li[aria-selected] .cm-completionMatchedText': {
    color:
      'var(--vscode-editorSuggestWidget-focusHighlightForeground, var(--vscode-editorSuggestWidget-highlightForeground))',
  },
  '.cm-completionDetail': {
    // Chrome font, so the detail (prose) can't be confused with the label (code).
    flex: '0 0 auto',
    marginLeft: 'auto',
    paddingLeft: '1.2em',
    fontFamily: 'var(--vscode-font-family)',
    fontSize: '0.68em',
    fontStyle: 'normal',
    color: 'var(--vscode-descriptionForeground)',
    whiteSpace: 'nowrap',
    overflow: 'hidden',
    textOverflow: 'ellipsis',
    maxWidth: '14em',
  },
  // CM6 has no glyph for several of our types, and each list is homogeneous
  // per trigger, so the icon column adds nothing.
  '.cm-completionIcon': {
    display: 'none',
  },

  // ── Find / replace panel (Cmd+F), see search-panel.ts ──
  // Floated top-right instead of CM6's flow bar that pushes the document
  // down. The accent is the caret colour, so it tracks the host's accent.
  '.cm-panels.cm-panels-top': {
    position: 'absolute',
    right: '0',
    left: 'auto',
    width: 'auto',
    maxWidth: '100%',
    // Band clearance in PADDING, not `top`: CM6 writes `top: 0px` inline.
    // Without `--chalk-chrome-top` the panel hides behind the host's opaque tab
    // strip while still taking focus. Pinned in Tests/browser/run.mjs.
    padding: 'calc(var(--chalk-chrome-top, 0px) + 8px) 12px 0 0',
    background: 'transparent',
    border: 'none',
    // above content/selection, below tooltips (base .cm-panels z-index=300).
    zIndex: '18',
  },
  // Enter only: CM6 removes the panel node on close, so there is no exit hook.
  '@keyframes cm-chalk-search-in': {
    from: { opacity: '0', transform: 'translateY(-6px)' },
    to: { opacity: '1', transform: 'translateY(0)' },
  },
  // One block: a second '@media (prefers-reduced-motion…)' key in this same
  // object literal would silently replace this one rather than merge.
  '@media (prefers-reduced-motion: no-preference)': {
    '.chalk-find': {
      animation: 'cm-chalk-search-in 110ms ease-out',
    },
    '.cm-tooltip.cm-tooltip-autocomplete': {
      animation: 'cm-chalk-complete-in 100ms ease-out',
    },
  },
  '.chalk-find': {
    // One knob: the query is set at the document's font size and every box
    // is a multiple of it. `calc(unit * k)`, not `em`, because nested `em`
    // compounds with each child's font-size. Ratios pinned in Tests/browser/run.mjs.
    '--find-unit': 'var(--vscode-editor-font-size, 13px)',
    display: 'flex',
    flexDirection: 'column',
    gap: 'calc(var(--find-unit) * 0.36)',
    boxSizing: 'border-box',
    minWidth: 'calc(var(--find-unit) * 19)',
    // Never wider than the column it floats over (narrow windows and splits).
    maxWidth: 'min(calc(var(--find-unit) * 26), 92vw)',
    padding: `calc(var(--find-unit) * 0.34) calc(var(--find-unit) * 0.42)
              calc(var(--find-unit) * 0.34) calc(var(--find-unit) * 0.58)`,
    backgroundColor: 'var(--vscode-editorSuggestWidget-background)',
    color: 'var(--vscode-editorSuggestWidget-foreground)',
    border: '1px solid var(--vscode-editorWidget-border, var(--vscode-widget-border, transparent))',
    borderRadius: 'calc(var(--find-unit) * 0.64)',
    boxShadow: '0 8px 26px rgba(28, 23, 15, 0.30), 0 1px 4px rgba(28, 23, 15, 0.16)',
    fontFamily: 'var(--vscode-font-family)',
    fontSize: 'calc(var(--find-unit) * 0.72)',
    transition: 'border-color 120ms ease, box-shadow 120ms ease',
  },
  '.chalk-find:focus-within': {
    borderColor: 'var(--vscode-editorCursor-foreground, #e2955c)',
    boxShadow:
      '0 8px 26px rgba(28, 23, 15, 0.30), 0 1px 4px rgba(28, 23, 15, 0.16), 0 0 0 2px color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 34%, transparent)',
  },
  '.chalk-find--invalid': {
    borderColor: 'var(--vscode-inputValidation-errorBorder, #d9534f)',
  },
  '.chalk-find__row': {
    display: 'flex',
    alignItems: 'center',
    gap: 'calc(var(--find-unit) * 0.3)',
  },
  // CSS size outranks the glyphs' width/height attributes, so icons scale too.
  '.chalk-find svg': {
    width: 'calc(var(--find-unit) * 0.86)',
    height: 'calc(var(--find-unit) * 0.86)',
  },
  '.chalk-find__icon': {
    display: 'flex',
    alignItems: 'center',
    flex: 'none',
    color: 'var(--vscode-editorLineNumber-foreground)',
  },
  '.chalk-find__input': {
    flex: '1 1 auto',
    minWidth: 'calc(var(--find-unit) * 7)',
    width: '0',
    background: 'transparent',
    border: 'none',
    outline: 'none',
    padding: 'calc(var(--find-unit) * 0.18) calc(var(--find-unit) * 0.12)',
    margin: '0',
    color: 'var(--vscode-editor-foreground)',
    fontFamily: 'var(--vscode-editor-font-family, var(--vscode-font-family))',
    fontSize: 'var(--find-unit)',
  },
  '.chalk-find__input::placeholder': {
    color: 'var(--vscode-editorLineNumber-foreground)',
  },
  '.chalk-find__count': {
    flex: 'none',
    padding: '0 calc(var(--find-unit) * 0.26)',
    color: 'var(--vscode-descriptionForeground)',
    fontSize: 'calc(var(--find-unit) * 0.7)',
    fontVariantNumeric: 'tabular-nums',
    whiteSpace: 'nowrap',
    userSelect: 'none',
  },
  '.chalk-find--invalid .chalk-find__count': {
    color: 'var(--vscode-inputValidation-errorBorder, #d9534f)',
  },
  '.chalk-find__nav': {
    display: 'flex',
    flex: 'none',
    gap: 'calc(var(--find-unit) * 0.06)',
  },
  '.chalk-find__icon-btn': {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    flex: 'none',
    width: 'calc(var(--find-unit) * 1.5)',
    height: 'calc(var(--find-unit) * 1.5)',
    padding: '0',
    background: 'transparent',
    border: 'none',
    borderRadius: 'calc(var(--find-unit) * 0.38)',
    color: 'var(--vscode-descriptionForeground)',
    cursor: 'pointer',
    transition: 'background-color 110ms ease, color 110ms ease',
  },
  '.chalk-find__icon-btn:hover': {
    backgroundColor: 'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 15%, transparent)',
    color: 'var(--vscode-editorCursor-foreground, #e2955c)',
  },
  '.chalk-find__close': {
    marginLeft: 'calc(var(--find-unit) * 0.12)',
  },
  '.chalk-find__toggle': {
    flex: 'none',
    minWidth: 'calc(var(--find-unit) * 1.56)',
    height: 'calc(var(--find-unit) * 1.5)',
    padding: '0 calc(var(--find-unit) * 0.3)',
    background: 'transparent',
    border: 'none',
    borderRadius: 'calc(var(--find-unit) * 0.38)',
    color: 'var(--vscode-descriptionForeground)',
    fontFamily: 'var(--vscode-editor-font-family, var(--vscode-font-family))',
    fontSize: 'calc(var(--find-unit) * 0.7)',
    fontWeight: '600',
    lineHeight: '1',
    cursor: 'pointer',
    transition: 'background-color 110ms ease, color 110ms ease',
  },
  '.chalk-find__toggle:hover': {
    backgroundColor: 'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 15%, transparent)',
    color: 'var(--vscode-editorSuggestWidget-foreground)',
  },
  '.chalk-find__toggle--on': {
    backgroundColor: 'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 22%, transparent)',
    color: 'var(--vscode-editorCursor-foreground, #e2955c)',
  },
  '.chalk-find__expand svg': {
    transition: 'transform 130ms ease',
  },
  '.chalk-find__expand--open svg': {
    transform: 'rotate(90deg)',
  },
  '.chalk-find__replace': {
    display: 'none',
  },
  '.chalk-find--replacing .chalk-find__replace': {
    display: 'flex',
  },
  '.chalk-find__replace-actions': {
    display: 'flex',
    flex: 'none',
    gap: 'calc(var(--find-unit) * 0.24)',
    marginLeft: 'auto',
  },
  '.chalk-find__text-btn': {
    flex: 'none',
    padding: 'calc(var(--find-unit) * 0.18) calc(var(--find-unit) * 0.54)',
    background: 'transparent',
    border: '1px solid var(--vscode-editorWidget-border, var(--vscode-widget-border, transparent))',
    borderRadius: 'calc(var(--find-unit) * 0.38)',
    color: 'var(--vscode-editorSuggestWidget-foreground)',
    fontFamily: 'var(--vscode-font-family)',
    fontSize: 'calc(var(--find-unit) * 0.7)',
    cursor: 'pointer',
    transition: 'background-color 110ms ease, border-color 110ms ease, color 110ms ease',
  },
  '.chalk-find__text-btn:hover': {
    backgroundColor: 'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 15%, transparent)',
    borderColor: 'var(--vscode-editorCursor-foreground, #e2955c)',
    color: 'var(--vscode-editorCursor-foreground, #e2955c)',
  },
  '.cm-searchMatch': {
    backgroundColor: 'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 20%, transparent)',
    borderRadius: '2px',
  },
  '.cm-searchMatch.cm-searchMatch-selected': {
    backgroundColor: 'color-mix(in srgb, var(--vscode-editorCursor-foreground, #e2955c) 44%, transparent)',
  },
});
