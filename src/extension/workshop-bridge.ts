import * as vscode from 'vscode';

const WORKSHOP_EXTENSION_ID = 'James-Yu.latex-workshop';

/**
 * Runs `latex-workshop.build` for the currently active Chalk-TeX document.
 *
 * Why the dance: LaTeX Workshop's root-file detection reads
 * `vscode.window.activeTextEditor.document`, which is `undefined` whenever
 * a custom editor owns the tab. We can't patch Workshop, so we transiently
 * open the same file in a native side-by-side text editor — that populates
 * `activeTextEditor`, Workshop's root detection succeeds, and the build
 * proceeds. `preserveFocus: true` keeps the user's caret in our webview.
 *
 * On subsequent invocations the side editor already exists (we detect via
 * `visibleTextEditors`), so no flicker.
 */
export async function buildWithWorkshop(): Promise<void> {
  const workshop = vscode.extensions.getExtension(WORKSHOP_EXTENSION_ID);
  if (!workshop) {
    vscode.window.showErrorMessage(
      'Chalk-TeX: LaTeX Workshop is not installed. Install James-Yu.latex-workshop to use Build.',
    );
    return;
  }
  if (!workshop.isActive) {
    await workshop.activate();
  }

  const uri = getActiveChalkTexUri();
  if (!uri) {
    vscode.window.showErrorMessage(
      'Chalk-TeX: no active .tex document to build.',
    );
    return;
  }

  const alreadyVisible = vscode.window.visibleTextEditors.some(
    (e) => e.document.uri.toString() === uri.toString(),
  );
  if (!alreadyVisible) {
    const doc = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(doc, {
      preview: false,
      preserveFocus: true,
      viewColumn: vscode.ViewColumn.Beside,
    });
  }

  await vscode.commands.executeCommand('latex-workshop.build');
}

function getActiveChalkTexUri(): vscode.Uri | null {
  const tab = vscode.window.tabGroups.activeTabGroup.activeTab;
  if (
    tab?.input instanceof vscode.TabInputCustom &&
    tab.input.viewType === 'chalk-tex.texEditor'
  ) {
    return tab.input.uri;
  }
  return null;
}
