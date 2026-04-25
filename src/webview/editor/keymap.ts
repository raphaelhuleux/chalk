import { KeyBinding } from '@codemirror/view';
import { sendCommand } from '../api';

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
 * Chalk keybindings that need to fire from inside the CM6-owned part
 * of the webview. VS Code keybindings with `when: activeCustomEditorId ==
 * …` also exist in package.json for gutters/scrollbars where CM6 doesn't
 * see the event — CM6 returning `true` from `run` stops propagation so
 * the two paths don't double-fire.
 */
export function chalkKeymap(): KeyBinding[] {
  return [
    {
      key: 'Mod-Alt-b',
      run: () => {
        sendCommand('chalk.build');
        return true;
      },
    },
  ];
}
