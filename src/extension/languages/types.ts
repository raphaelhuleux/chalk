import type { ThemeColors } from '../theme-reader';

/**
 * Per-language data passed into ChalkEditorProvider. Captures everything
 * the host shell needs to know that depends on the file type — viewType
 * registration, hsnips loading, theme scopes.
 *
 * The webview-side language switch (markdown vs stex CM extensions, math
 * detection strategy, live-preview decorations) is driven separately by
 * the `language` field carried in the `init` message — see
 * src/webview/editor/setup.ts.
 */
export interface LanguageProfile {
  /** Unique webview-side identifier. Sent in the `init` message; setup.ts
   *  branches on it to choose CM6 extensions. */
  id: 'tex' | 'md';

  /** Custom-editor viewType registered in package.json's customEditors. */
  viewType: string;

  /** TextMate scope candidates per CM6 highlight tag, used by theme-reader
   *  to look up colors in the active theme's tokenColors. Empty for languages
   *  that don't drive a syntax HighlightStyle (md uses lezer-markdown's
   *  built-in highlighting + a separate heading-color path). */
  themeScopeCandidates: Record<keyof ThemeColors, string[]>;

  /** Read all hsnips files relevant to this language and return their raw
   *  text concatenated. Returns null if none exist. Called once per editor
   *  open, on the `ready` message. */
  loadHsnips: () => string | null;
}
