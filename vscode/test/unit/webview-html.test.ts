import { readFileSync } from 'node:fs';
import * as path from 'node:path';
import { describe, expect, it } from 'vitest';
import { getWebviewHtml, generateNonce } from '../../src/extension/webview-html';

/**
 * Locks the webview shell's editor sizing. Without a height-constrained
 * #editor-root/.cm-editor the page body becomes the scroll container and
 * scrollPastEnd()'s spacer — sized from the editor's own height — feeds back
 * on itself: measured runaway past 1.5M px of blank space below the last
 * line (the "editor jumps below the last line / infinite scroll" bug).
 * The rules now live in editor-core's styles/host-shell.css, shared with the
 * native host and pulled into the webview through dist/webview.css, so this
 * checks the link and the shared file's content.
 */

const fakeWebview = {
  asWebviewUri: (u: { toString(): string }) => u.toString(),
  cspSource: 'https://file+.vscode-resource.test',
} as never;

const extensionUri = { fsPath: '/ext' } as never;

function html(): string {
  return getWebviewHtml(fakeWebview, extensionUri, generateNonce());
}

/** Collapse whitespace so formatting churn doesn't break the lock. */
function flat(s: string): string {
  return s.replace(/\s+/g, ' ');
}

const hostShellCss = readFileSync(
  path.resolve(__dirname, '../../../packages/editor-core/src/styles/host-shell.css'),
  'utf8',
);

describe('getWebviewHtml editor sizing', () => {
  it('links the bundled stylesheet that carries the shell sizing', () => {
    expect(flat(html())).toContain('<link rel="stylesheet" href=');
    expect(flat(html())).toContain('webview.css');
  });

  it('pins html, body, and #editor-root to full height (shared host-shell.css)', () => {
    expect(flat(hostShellCss)).toContain('html, body, #root, #editor-root { margin: 0; height: 100%; }');
  });

  it('disables page-level scrolling so .cm-scroller is the scroll container', () => {
    expect(flat(hostShellCss)).toContain('body {');
    expect(flat(hostShellCss)).toContain('overflow: hidden;');
  });

  it('sizes the editor to its container', () => {
    expect(flat(hostShellCss)).toContain('.cm-editor { height: 100%; }');
  });

  it("keeps style-src 'unsafe-inline' — CM6 injects <style> tags at runtime", () => {
    const csp = /http-equiv="Content-Security-Policy" content="([^"]*)"/.exec(html());
    expect(csp).not.toBeNull();
    const styleSrc = csp![1].split(';').find((d) => d.trim().startsWith('style-src'));
    expect(styleSrc).toContain("'unsafe-inline'");
  });
});
