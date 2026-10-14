/**
 * The host seam: editor-core is host-agnostic, and a `HostPort` speaking this
 * frozen 9-message protocol is its only host contact. Hosts: the native app
 * (web/src/native-host.ts, Swift Codable mirrors in mac/ChalkKit's
 * HostProtocol.swift) and VS Code (vscode/src/webview-entry.ts). Changing a
 * message means changing both hosts and the Swift mirror together.
 */
import type { Language } from './editor/setup';

export type ThemeColors = Partial<{
  keyword: string | null;
  tagName: string | null;
  comment: string | null;
  number: string | null;
  atom: string | null;
  bracket: string | null;
  specialVariable: string | null;
  invalid: string | null;
}>;

export type HeadingColors = Partial<Record<1 | 2 | 3 | 4 | 5 | 6, string>>;

/**
 * Host to editor (6 inbound types).
 *
 * `epoch` (optional, native host only): the host's text-push generation, echoed
 * on each `edit` so the host can drop edits made against a buffer it has since
 * replaced (a keystroke racing a tab switch). Hosts that never send it get
 * `edit` without it.
 */
export type HostToEditorMessage =
  | { type: 'init'; text: string; language: Language; editorConfig?: unknown; epoch?: number }
  | { type: 'update'; text: string; epoch?: number }
  | { type: 'theme-colors'; colors: ThemeColors }
  | { type: 'heading-colors'; colors: HeadingColors }
  | { type: 'editor-config'; config: unknown }
  | { type: 'hsnips'; content: string };

/** Editor to host (3 outbound types). */
export type EditorToHostMessage =
  | { type: 'ready' }
  | { type: 'edit'; text: string; epoch?: number }
  | { type: 'open-external'; url: string };

export interface HostPort {
  send(msg: EditorToHostMessage): void;
  /** Host pushes inbound messages; returns an unsubscribe function. */
  onMessage(handler: (msg: HostToEditorMessage) => void): () => void;
}

// Module-scoped so leaf modules (md-live-preview's link handler) can post
// without threading the port through. Set by `mountEditor()`, cleared on destroy.
let currentPort: HostPort | null = null;

export function setPort(port: HostPort | null): void {
  currentPort = port;
}

/** Clear the module port only if it is still `port`, so destroying one of two
 *  mounts on a page doesn't cut off the other. The last mount wins openExternal;
 *  real hosts run one editor per page. */
export function clearPort(port: HostPort): void {
  if (currentPort === port) currentPort = null;
}

/** Open a URL in the host's default browser (md-live-preview link clicks). */
export function openExternal(url: string): void {
  currentPort?.send({ type: 'open-external', url });
}
