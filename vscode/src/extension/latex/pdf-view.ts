import * as vscode from 'vscode';
import { existsSync } from 'node:fs';
import * as path from 'node:path';
import { texProfile } from '../languages/tex';
import { LW_EXTENSION_ID, isOpenInChalkTexEditor, type LatexBuilder } from './build-on-save';

/**
 * `chalk.latex.build` / `chalk.latex.viewPdf` and reverse SyncTeX into Chalk.
 *
 * LW's own build, view and SyncTeX commands all bail without an active LaTeX
 * text editor, so they are dead while a Chalk tab has focus. Its PDF viewer is
 * a custom editor on `*.pdf` that refreshes itself when the file changes, so
 * opening that directly works. Forward SyncTeX (source to PDF) has no entry
 * point outside LW and stays unsupported until LW takes a URI and line.
 */

/** LW's PDF viewer custom editor (its package.json `customEditors`). */
const LW_PDF_VIEW_TYPE = 'latex-workshop-pdf-hook';
/** How long after the PDF viewer loses focus a new text tab still counts as
 *  its reverse SyncTeX jump. */
const REVERSE_SYNC_WINDOW_MS = 1500;
/** LW sets the selection after `showTextDocument` resolves; wait this long
 *  for it before reading the line. */
const SELECTION_WAIT_MS = 600;

function isPdfViewerTab(tab: vscode.Tab | undefined): boolean {
  const input = tab?.input;
  if (input instanceof vscode.TabInputCustom) return input.viewType === LW_PDF_VIEW_TYPE;
  // LW's panel mode (`view.pdf.viewer: tab` on older setups) is a plain webview.
  return input instanceof vscode.TabInputWebview && input.viewType.includes('latex-workshop-pdf');
}

function findTab(match: (tab: vscode.Tab) => boolean): vscode.Tab | undefined {
  for (const group of vscode.window.tabGroups.all) {
    const tab = group.tabs.find(match);
    if (tab) return tab;
  }
  return undefined;
}

const sameUri = (a: vscode.Uri, b: vscode.Uri): boolean => a.toString() === b.toString();

function chalkTabFor(uri: vscode.Uri): vscode.Tab | undefined {
  return findTab(
    (t) => t.input instanceof vscode.TabInputCustom && t.input.viewType === texProfile.viewType && sameUri(t.input.uri, uri),
  );
}

/** The .tex document the user is looking at: the active Chalk tab, else a
 *  .tex text editor. */
function activeTexUri(): vscode.Uri | undefined {
  const input = vscode.window.tabGroups.activeTabGroup.activeTab?.input;
  if (input instanceof vscode.TabInputCustom && input.viewType === texProfile.viewType) return input.uri;
  const doc = vscode.window.activeTextEditor?.document;
  return doc && doc.fileName.endsWith('.tex') ? doc.uri : undefined;
}

async function openPdf(pdf: vscode.Uri): Promise<void> {
  if (vscode.extensions.getExtension(LW_EXTENSION_ID) === undefined) {
    // VS Code has no PDF viewer of its own.
    await vscode.env.openExternal(pdf);
    return;
  }
  const existing = findTab((t) => isPdfViewerTab(t) && t.input instanceof vscode.TabInputCustom && sameUri(t.input.uri, pdf));
  await vscode.commands.executeCommand('vscode.openWith', pdf, LW_PDF_VIEW_TYPE, {
    viewColumn: existing?.group.viewColumn ?? vscode.ViewColumn.Beside,
    preserveFocus: true,
  });
}

async function viewPdf(builder: LatexBuilder): Promise<void> {
  const uri = activeTexUri();
  if (!uri || uri.scheme !== 'file') {
    void vscode.window.showInformationMessage('Chalk: open a .tex file to view its PDF.');
    return;
  }
  const { root, reason } = builder.resolveRoot(uri.fsPath);
  if (!root) {
    void vscode.window.showWarningMessage(`Chalk: no LaTeX root for ${path.basename(uri.fsPath)} (${reason}).`);
    return;
  }
  const pdf = builder.pdfPath(root);
  if (!existsSync(pdf)) {
    if (!builder.isBuilding(root)) {
      await builder.buildNow(await vscode.workspace.openTextDocument(uri));
    }
    await builder.idle(root);
    if (!existsSync(pdf)) {
      void vscode.window.showErrorMessage(`Chalk: no PDF at ${pdf} (see the Chalk LaTeX log).`);
      builder.channel.show(true);
      return;
    }
  }
  await openPdf(vscode.Uri.file(pdf));
}

/**
 * LW answers a click in its PDF with `showTextDocument`, which opens a raw
 * text tab even when the file is open in Chalk. When that text tab is new and
 * appears while (or just after) the PDF viewer had focus, move the jump to the
 * Chalk tab and close the text tab. Text tabs the user opened themselves are
 * never touched: they are not new, or the PDF was not focused.
 */
function installReverseSync(revealLine: (uri: vscode.Uri, line: number) => boolean): vscode.Disposable {
  let pdfActive = isPdfViewerTab(vscode.window.tabGroups.activeTabGroup.activeTab);
  let pdfLeftAt = 0;
  const trackPdfFocus = (): void => {
    const now = isPdfViewerTab(vscode.window.tabGroups.activeTabGroup.activeTab);
    if (pdfActive && !now) pdfLeftAt = Date.now();
    pdfActive = now;
  };
  const fromPdf = (): boolean => pdfActive || Date.now() - pdfLeftAt < REVERSE_SYNC_WINDOW_MS;

  const redirect = async (uri: vscode.Uri): Promise<void> => {
    const line = await new Promise<number>((resolve) => {
      const current = (): number =>
        vscode.window.visibleTextEditors.find((ed) => sameUri(ed.document.uri, uri))?.selection.active.line ?? 0;
      const timer = setTimeout(() => {
        sub.dispose();
        resolve(current());
      }, SELECTION_WAIT_MS);
      const sub = vscode.window.onDidChangeTextEditorSelection((e) => {
        if (!sameUri(e.textEditor.document.uri, uri)) return;
        clearTimeout(timer);
        sub.dispose();
        resolve(e.selections[0].active.line);
      });
    });
    const chalkTab = chalkTabFor(uri);
    if (!chalkTab) return;
    await vscode.commands.executeCommand('vscode.openWith', uri, texProfile.viewType, {
      viewColumn: chalkTab.group.viewColumn,
      preserveFocus: false,
    });
    const textTab = findTab((t) => t.input instanceof vscode.TabInputText && sameUri(t.input.uri, uri));
    if (textTab) await vscode.window.tabGroups.close(textTab, true);
    revealLine(uri, line + 1);
  };

  const tabsSub = vscode.window.tabGroups.onDidChangeTabs((e) => {
    const jumped = fromPdf();
    trackPdfFocus();
    if (!jumped) return;
    if (!vscode.workspace.getConfiguration('chalk.latex').get<boolean>('reverseSyncToChalk', true)) return;
    for (const tab of e.opened) {
      if (!(tab.input instanceof vscode.TabInputText)) continue;
      const uri = tab.input.uri;
      if (uri.fsPath.endsWith('.tex') && isOpenInChalkTexEditor(uri)) void redirect(uri);
    }
  });
  const groupsSub = vscode.window.tabGroups.onDidChangeTabGroups(trackPdfFocus);
  return vscode.Disposable.from(tabsSub, groupsSub);
}

export function installLatexCommands(
  builder: LatexBuilder,
  revealLine: (uri: vscode.Uri, line: number) => boolean,
): vscode.Disposable {
  return vscode.Disposable.from(
    vscode.commands.registerCommand('chalk.latex.build', async () => {
      const uri = activeTexUri();
      if (!uri || uri.scheme !== 'file') {
        void vscode.window.showInformationMessage('Chalk: open a .tex file to build it.');
        return;
      }
      await builder.buildNow(await vscode.workspace.openTextDocument(uri));
    }),
    vscode.commands.registerCommand('chalk.latex.viewPdf', () => viewPdf(builder)),
    installReverseSync(revealLine),
  );
}
