import type { ThemeColors } from '../theme-reader';

/**
 * Per-language host data for ChalkEditorProvider. The webview-side language
 * switch is driven by the `language` field of `init` (editor-core setup.ts).
 */
export interface LanguageProfile {
  /** Sent as `init`'s `language`. */
  id: 'tex' | 'md';

  /** Custom-editor viewType registered in package.json's customEditors. */
  viewType: string;

  /** Language id for scoped settings (`[markdown]` / `[latex]` blocks), so
   *  Chalk uses the same `editor.*` values as a plain text editor would. */
  settingsLanguageId: string;

  /** TextMate scope candidates per highlight tag, in priority order. An
   *  empty list leaves that tag on the engine's fallback colour. */
  themeScopeCandidates: Record<keyof ThemeColors, string[]>;

  /** Raw hsnips text for this language; null sends nothing. Called on
   *  `ready` and again when snippet files or hsnips.hsnipsPath change. */
  loadHsnips: () => string | null;
}
