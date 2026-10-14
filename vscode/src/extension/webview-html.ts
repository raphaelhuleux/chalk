import * as vscode from 'vscode';
import { randomBytes } from 'crypto';

/** Per-load CSP nonce; crypto.randomBytes because it must be unpredictable. */
export function generateNonce(): string {
  return randomBytes(16).toString('hex');
}

/**
 * The HTML shell served inside the webview. style-src needs 'unsafe-inline'
 * because CM6 injects <style> tags. No `https:` source: an open img-src would
 * be an exfiltration channel for attacker-controlled URLs.
 */
export function getWebviewHtml(
  webview: vscode.Webview,
  extensionUri: vscode.Uri,
  nonce: string,
): string {
  const scriptUri = webview.asWebviewUri(
    vscode.Uri.joinPath(extensionUri, 'dist', 'webview.js'),
  );
  const styleUri = webview.asWebviewUri(
    vscode.Uri.joinPath(extensionUri, 'dist', 'webview.css'),
  );
  // Injected by the webview on the first ```mermaid fence, with this page's
  // nonce (webview-entry.ts reads both).
  const mermaidUri = webview.asWebviewUri(
    vscode.Uri.joinPath(extensionUri, 'dist', 'mermaid.js'),
  );

  const csp = [
    `default-src 'none'`,
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
    `font-src ${webview.cspSource} data:`,
    `img-src ${webview.cspSource} data:`,
  ].join('; ');

  // Shell sizing comes from editor-core's styles/host-shell.css, folded into
  // dist/webview.css via webview-entry.ts.
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <link rel="stylesheet" href="${styleUri}">
  <title>Chalk</title>
</head>
<body>
  <div id="editor-root" data-mermaid-src="${mermaidUri}"></div>
  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
