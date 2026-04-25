import * as vscode from 'vscode';

/**
 * Cryptographically-unimportant but unique-per-load string used in the CSP
 * to authorize exactly one inline script tag per HTML document. Matches the
 * recommendation in the VS Code Webview API guide.
 */
export function generateNonce(): string {
  const chars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  for (let i = 0; i < 32; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

/**
 * Builds the HTML shell served inside the webview.
 *
 * Unlike its Chalk-for-Markdown sibling, the tex editor doesn't inject any
 * per-scope theme colors — no headings, no syntax-specific tokens are
 * rendered inline, only math widgets that inherit the editor's foreground.
 *
 * CSP notes:
 *   - default-src 'none' — deny everything by default.
 *   - script-src 'nonce-X' — only our one script tag runs.
 *   - style-src ... 'unsafe-inline' — CM6 injects <style> tags at runtime.
 *   - font-src ... data: — KaTeX fonts may inline as data URIs.
 *   - img-src ... data: https: — room for future features.
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

  const csp = [
    `default-src 'none'`,
    `style-src ${webview.cspSource} 'unsafe-inline'`,
    `script-src 'nonce-${nonce}'`,
    `font-src ${webview.cspSource} data:`,
    `img-src ${webview.cspSource} data: https:`,
  ].join('; ');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Security-Policy" content="${csp}">
  <link rel="stylesheet" href="${styleUri}">
  <title>Chalk</title>
</head>
<body>
  <div id="editor-root"></div>
  <script nonce="${nonce}" src="${scriptUri}"></script>
</body>
</html>`;
}
