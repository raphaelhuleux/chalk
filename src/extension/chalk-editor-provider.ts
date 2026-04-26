import * as vscode from 'vscode';
import { getWebviewHtml, generateNonce } from './webview-html';
import { readThemeColors } from './theme-reader';
import { getMarkdownHeadingColors } from './markdown-heading-colors';
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
    // A depth counter (not a boolean) so overlapping edits don't drop the
    // guard early; try/finally so a rejected applyEdit doesn't strand it.
    let applyEditDepth = 0;

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
      const colors = await readThemeColors(this.profile.themeScopeCandidates);
      if (!colors) return;
      webviewPanel.webview.postMessage({ type: 'theme-colors', colors });
    };

    const postHeadingColors = (): void => {
      if (this.profile.id !== 'md') return;
      const colors = getMarkdownHeadingColors();
      webviewPanel.webview.postMessage({ type: 'heading-colors', colors });
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
          postHeadingColors();

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
          const edit = new vscode.WorkspaceEdit();
          edit.replace(
            document.uri,
            new vscode.Range(0, 0, document.lineCount, 0),
            msg.text,
          );
          applyEditDepth++;
          try {
            await vscode.workspace.applyEdit(edit);
          } finally {
            applyEditDepth--;
          }
          return;
        }
        case 'open-external': {
          if (typeof msg.url !== 'string') return;
          void vscode.env.openExternal(vscode.Uri.parse(msg.url));
          return;
        }
      }
    });

    const changeSub = vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.toString() !== document.uri.toString()) return;
      if (applyEditDepth > 0) return;
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
      if (webviewReady) {
        void postThemeColors();
        postHeadingColors();
      }
    });

    webviewPanel.onDidDispose(() => {
      messageSub.dispose();
      changeSub.dispose();
      viewStateSub.dispose();
      themeSub.dispose();
    });
  }
}
