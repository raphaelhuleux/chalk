/**
 * Webview → extension messaging helpers.
 *
 * The VS Code webview API handle (returned by acquireVsCodeApi()) must be
 * acquired exactly once per webview load. `src/webview/index.ts` acquires
 * it at startup and passes it into setVsCodeApi() below, after which any
 * module can post messages via the exported helpers.
 */

interface VsCodeApi {
  postMessage(msg: unknown): void;
  getState(): unknown;
  setState(state: unknown): void;
}

let api: VsCodeApi | null = null;

export function setVsCodeApi(handle: VsCodeApi): void {
  api = handle;
}

export function postMessage(msg: unknown): void {
  if (!api) {
    throw new Error('VS Code API handle not set. Call setVsCodeApi() first.');
  }
  api.postMessage(msg);
}

export function openExternal(url: string): void {
  postMessage({ type: 'open-external', url });
}

export function sendEdit(text: string): void {
  postMessage({ type: 'edit', text });
}

export function sendReady(): void {
  postMessage({ type: 'ready' });
}
