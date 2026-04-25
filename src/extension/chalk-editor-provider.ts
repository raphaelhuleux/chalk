import * as vscode from 'vscode';
import { getWebviewHtml, generateNonce } from './webview-html';
import { readThemeColors } from './theme-reader';
import type { LanguageProfile } from './languages/types';

export class ChalkEditorProvider implements vscode.CustomTextEditorProvider {
  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly profile: LanguageProfile,
  ) {}

  public async resolveCustomTextEditor(
    document: vscode.TextDocument,
    webviewPanel: vscode.WebviewPanel,
    _token: vscode.CancellationToken,
  ): Promise<void> {
    webviewPanel.webview.options = {
      enableScripts: true,
      localResourceRoots: [
        vscode.Uri.joinPath(this.context.extensionUri, 'dist'),
      ],
    };

    const nonce = generateNonce();
    webviewPanel.webview.html = getWebviewHtml(
      webviewPanel.webview,
      this.context.extensionUri,
      nonce,
    );

    // Sync-loop prevention. See Chalk's CLAUDE.md for the full reasoning —
    // the short version is that our own WorkspaceEdit fires
    // onDidChangeTextDocument, which we must ignore to avoid a ping-pong.
    let isApplyingOwnEdit = false;

    let webviewReady = false;
    let pendingUpdate: string | null = null;

    const postUpdate = (text: string): void => {
      if (!webviewReady) {
        pendingUpdate = text;
        return;
      }
      webviewPanel.webview.postMessage({ type: 'update', text });
    };

    const postThemeColors = async (): Promise<void> => {
      const colors = await readThemeColors();
      if (!colors) return;
      webviewPanel.webview.postMessage({ type: 'theme-colors', colors });
    };

    const messageSub = webviewPanel.webview.onDidReceiveMessage(async (msg) => {
      switch (msg.type) {
        case 'ready': {
          webviewReady = true;
          webviewPanel.webview.postMessage({
            type: 'init',
            text: document.getText(),
            language: this.profile.id,
          });
          void postThemeColors();

          const hsnipsRaw = this.profile.loadHsnips();
          if (hsnipsRaw) {
            webviewPanel.webview.postMessage({
              type: 'hsnips',
              content: hsnipsRaw,
            });
          }

          if (pendingUpdate !== null) {
            webviewPanel.webview.postMessage({
              type: 'update',
              text: pendingUpdate,
            });
            pendingUpdate = null;
          }
          return;
        }
        case 'edit': {
          if (typeof msg.text !== 'string') return;
          if (msg.text === document.getText()) return;
          isApplyingOwnEdit = true;
          const edit = new vscode.WorkspaceEdit();
          edit.replace(
            document.uri,
            new vscode.Range(0, 0, document.lineCount, 0),
            msg.text,
          );
          await vscode.workspace.applyEdit(edit);
          isApplyingOwnEdit = false;
          return;
        }
        case 'open-external': {
          if (typeof msg.url !== 'string') return;
          void vscode.env.openExternal(vscode.Uri.parse(msg.url));
          return;
        }
        case 'command': {
          // Whitelist: only commands explicitly owned by Chalk can be
          // dispatched from the webview. Prevents an accidental future
          // regression where this handler turns into an arbitrary-command
          // executor for anyone who can post a message.
          if (typeof msg.id !== 'string') return;
          if (!this.profile.allowedWebviewCommands.has(msg.id)) return;
          await vscode.commands.executeCommand(msg.id);
          return;
        }
      }
    });

    const changeSub = vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.toString() !== document.uri.toString()) return;
      if (isApplyingOwnEdit) return;
      postUpdate(e.document.getText());
    });

    const viewStateSub = webviewPanel.onDidChangeViewState(() => {
      if (webviewPanel.visible && webviewReady) {
        webviewPanel.webview.postMessage({
          type: 'update',
          text: document.getText(),
        });
      }
    });

    const themeSub = vscode.window.onDidChangeActiveColorTheme(() => {
      if (webviewReady) void postThemeColors();
    });

    webviewPanel.onDidDispose(() => {
      messageSub.dispose();
      changeSub.dispose();
      viewStateSub.dispose();
      themeSub.dispose();
    });
  }
}
