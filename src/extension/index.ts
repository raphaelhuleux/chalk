import * as vscode from 'vscode';
import { ChalkTexEditorProvider } from './chalk-tex-editor-provider';

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(
      ChalkTexEditorProvider.viewType,
      new ChalkTexEditorProvider(context),
      {
        webviewOptions: {
          // CM6 state survives tab switches (undo, cursor, scroll).
          retainContextWhenHidden: true,
        },
        supportsMultipleEditorsPerDocument: false,
      },
    ),
  );

  // Cmd+: is handled at the keybinding level in package.json — bound to
  // VS Code's built-in `workbench.action.reopenWithEditor`, which opens
  // a picker for flipping between Chalk-TeX and the text editor.
}

export function deactivate(): void {
  // Provider subscriptions are disposed via context.subscriptions.
}
