import * as vscode from 'vscode';
import { ChalkEditorProvider } from './chalk-editor-provider';
import { texProfile } from './languages/tex';
import { buildWithWorkshop } from './workshop-bridge';
import { diagnoseThemeResolution } from './theme-reader';

export function activate(context: vscode.ExtensionContext): void {
  const diagChannel = vscode.window.createOutputChannel('Chalk');

  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(
      texProfile.viewType,
      new ChalkEditorProvider(context, texProfile),
      {
        webviewOptions: {
          // CM6 state survives tab switches (undo, cursor, scroll).
          retainContextWhenHidden: true,
        },
        supportsMultipleEditorsPerDocument: false,
      },
    ),
    vscode.commands.registerCommand('chalk.build', buildWithWorkshop),
    vscode.commands.registerCommand('chalk.diagnoseTheme', async () => {
      const diag = await diagnoseThemeResolution();
      diagChannel.clear();
      diagChannel.appendLine(JSON.stringify(diag, null, 2));
      diagChannel.show(true);
    }),
    diagChannel,
  );

  // Cmd+: is handled at the keybinding level in package.json — bound to
  // VS Code's built-in `workbench.action.reopenWithEditor`, which opens
  // a picker for flipping between Chalk and the text editor.
}

export function deactivate(): void {
  // Provider subscriptions are disposed via context.subscriptions.
}
