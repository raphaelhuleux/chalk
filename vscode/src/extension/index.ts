import * as vscode from 'vscode';
import { ChalkEditorProvider } from './chalk-editor-provider';
import { diagnoseThemeResolution } from './theme-reader';
import { installLatexBuildOnSave } from './latex/build-on-save';
import { texProfile } from './languages/tex';
import { markdownProfile } from './languages/markdown';

export function activate(context: vscode.ExtensionContext): void {
  const diagChannel = vscode.window.createOutputChannel('Chalk');

  const editorOptions = {
    webviewOptions: {
      // CM6 state survives tab switches (undo, cursor, scroll).
      retainContextWhenHidden: true,
    },
    supportsMultipleEditorsPerDocument: false,
  };

  context.subscriptions.push(
    vscode.window.registerCustomEditorProvider(
      texProfile.viewType,
      new ChalkEditorProvider(context, texProfile, diagChannel),
      editorOptions,
    ),
    vscode.window.registerCustomEditorProvider(
      markdownProfile.viewType,
      new ChalkEditorProvider(context, markdownProfile, diagChannel),
      editorOptions,
    ),
    vscode.commands.registerCommand('chalk.diagnoseTheme', async () => {
      // Pick the profile that matches the currently-focused custom editor;
      // fall back to tex.
      const tab = vscode.window.tabGroups.activeTabGroup.activeTab;
      const profile =
        tab?.input instanceof vscode.TabInputCustom &&
        tab.input.viewType === markdownProfile.viewType
          ? markdownProfile
          : texProfile;
      const diag = await diagnoseThemeResolution(profile.themeScopeCandidates);
      diagChannel.clear();
      diagChannel.appendLine(JSON.stringify(diag, null, 2));
      diagChannel.show(true);
    }),
    // No-op target of the undo/redo keybindings in package.json. VS Code's
    // preload forwards every webview keydown to the workbench, whose `undo`
    // would undo the TextDocument on top of CodeMirror's own undo
    // (test/unit/keybindings.test.ts).
    vscode.commands.registerCommand('chalk.editorHandledKey', () => {}),
    installLatexBuildOnSave(diagChannel),
    diagChannel,
  );
}

export function deactivate(): void {
  // Provider subscriptions are disposed via context.subscriptions.
}
