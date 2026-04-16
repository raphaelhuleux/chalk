import { KeyBinding } from '@codemirror/view';

/**
 * Callbacks from the editor host (webview bootstrap). Chalk used to own
 * several bindings (save, new, close, tab-nav, source-toggle); VS Code now
 * owns all of them, so the only callback the editor still needs from the
 * host is the content-change notification.
 */
export interface EditorActions {
  onContentChange: (content: string) => void;
}

/**
 * Chalk-specific keybindings. Currently empty — VS Code owns all the
 * keybindings we care about (Cmd+S, Cmd+N, Cmd+:, Ctrl+Tab, etc.). Kept
 * as a slot so new Chalk-specific bindings can be added without reshaping
 * setup.ts.
 */
export function chalkKeymap(_actions: EditorActions): KeyBinding[] {
  return [];
}
