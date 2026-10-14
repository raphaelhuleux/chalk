/**
 * Minimal vscode stub for use in vitest. Only covers the surface that
 * webview-html.ts touches: Uri.joinPath.
 */
export const Uri = {
  joinPath: (uri: { fsPath: string }, ...parts: string[]) => ({
    fsPath: [uri.fsPath, ...parts].join('/'),
    toString: () => [uri.fsPath, ...parts].join('/'),
  }),
};
