/**
 * Webview entry for the VS Code extension: wraps the webview API in a HostPort
 * and mounts editor-core. esbuild bundles it to dist/webview.js and
 * dist/webview.css.
 */
import {
  createRequestChannel,
  mountEditor,
  REPLY_FIELDS,
  requestHooks,
  scriptMermaidLoader,
  type HostPort,
  type HostToEditorMessage,
} from '@chalk/editor-core';
// Page-level shell sizing, shared with the native host.
import '@chalk/editor-core/styles/host-shell.css';
// Extension-side module, safe here only because it has no imports.
import { HEARTBEAT_MS } from './extension/webview-watchdog';

interface VsCodeApi {
  postMessage(msg: unknown): void;
  getState(): unknown;
  setState(state: unknown): void;
}
declare function acquireVsCodeApi(): VsCodeApi;

const vscode = acquireVsCodeApi();

// Only set while this script runs: the mermaid script is injected later and
// needs the same nonce to pass the CSP.
const scriptNonce = (document.currentScript as HTMLScriptElement | null)?.nonce || undefined;

const port: HostPort = {
  send: (msg) => vscode.postMessage(msg),
  onMessage: (handler) => {
    const listener = (e: MessageEvent): void => {
      // Request-channel replies are not HostPort messages; letting them
      // through would trip mount.ts's malformed-message warning.
      const data = e.data as { type?: unknown };
      if (data && typeof data.type === 'string' && (requests.isReply(data.type) || data.type === 'goto-line')) return;
      handler(e.data as HostToEditorMessage);
    };
    window.addEventListener('message', listener);
    return () => window.removeEventListener('message', listener);
  },
};

// Host requests: request/reply keyed by id (editor-core's host-request.ts,
// shared with the native bridge). Transport glue, not part of the frozen
// HostPort protocol.
const requests = createRequestChannel((msg) => vscode.postMessage(msg));
const { resolveAsset, workspaceAccess } = requestHooks(requests);

window.addEventListener('message', (e: MessageEvent) => {
  const data = e.data as { type?: unknown; id?: unknown } & Record<string, unknown>;
  if (!data || typeof data.type !== 'string' || typeof data.id !== 'number') return;
  if (!requests.isReply(data.type)) return;
  requests.settle(data.id, data[REPLY_FIELDS[data.type]] ?? null);
});

// Crash telemetry for the "Chalk" output channel. Like the heartbeat, this
// is VS Code glue outside the HostPort protocol.
window.addEventListener('error', (e) => {
  vscode.postMessage({
    type: 'client-error',
    message: String(e.message ?? e),
    stack: e.error instanceof Error ? (e.error.stack ?? null) : null,
  });
});
window.addEventListener('unhandledrejection', (e) => {
  const reason: unknown = e.reason;
  vscode.postMessage({
    type: 'client-error',
    message: reason instanceof Error ? reason.message : String(reason),
    stack: reason instanceof Error ? (reason.stack ?? null) : null,
  });
});

const root = document.getElementById('editor-root');
if (!root) {
  throw new Error('#editor-root not found');
}
const mermaidSrc = root.dataset.mermaidSrc;
const editor = mountEditor({
  root,
  port,
  resolveAsset,
  workspaceAccess,
  loadMermaid: mermaidSrc ? scriptMermaidLoader(mermaidSrc, scriptNonce) : undefined,
});

// Reverse SyncTeX lands here (latex/pdf-view.ts): VS Code glue, outside
// the HostPort protocol, so the port listener above drops it.
window.addEventListener('message', (e: MessageEvent) => {
  const data = e.data as { type?: unknown; line?: unknown };
  if (data?.type === 'goto-line' && typeof data.line === 'number') editor.gotoLine(data.line);
});

// Liveness signal for WebviewWatchdog. Started only after a successful mount:
// silence from a failed boot is what triggers the watchdog's reload.
setInterval(() => vscode.postMessage({ type: 'heartbeat' }), HEARTBEAT_MS);
