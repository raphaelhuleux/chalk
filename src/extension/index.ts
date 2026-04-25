import * as vscode from 'vscode';
import { ChalkTexEditorProvider } from './chalk-tex-editor-provider';
import { buildWithWorkshop } from './workshop-bridge';
import { diagnoseThemeResolution } from './theme-reader';

export function activate(context: vscode.ExtensionContext): void {
  const diagChannel = vscode.window.createOutputChannel('Chalk-TeX');

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
    vscode.commands.registerCommand('chalk-tex.build', buildWithWorkshop),
    vscode.commands.registerCommand('chalk-tex.diagnoseTheme', async () => {
      const diag = await diagnoseThemeResolution();
      diagChannel.clear();
      diagChannel.appendLine(JSON.stringify(diag, null, 2));
      diagChannel.show(true);
    }),
    diagChannel,
  );

  // Cmd+: is handled at the keybinding level in package.json — bound to
  // VS Code's built-in `workbench.action.reopenWithEditor`, which opens
  // a picker for flipping between Chalk-TeX and the text editor.
}

export function deactivate(): void {
  // Provider subscriptions are disposed via context.subscriptions.
}
