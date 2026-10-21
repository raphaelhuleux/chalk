/**
 * The Mac app's HostPort transport, the WKWebView analog of
 * vscode/src/webview-entry.ts. Mirrored on the Swift side by
 * mac/Chalk/Editor/WebEditorSurface.swift (bridges, internal messages) and
 * ChalkKit's HostProtocol.swift (message types): change them together.
 *
 * Editor → host:  port.send(msg)  →  webkit.messageHandlers.chalkHost.postMessage
 * Host → editor:  Swift evaluates window.__chalkHost.receive(msg)  →  onMessage
 */
import {
  createRequestChannel,
  mountEditor,
  requestHooks,
  scriptMermaidLoader,
  type HostPort,
  type HostToEditorMessage,
  type EditorToHostMessage,
  type OutlineSnapshot,
  type TikzResult,
} from '@chalk/editor-core';
// Page-level shell sizing, shared with the VS Code host. Imported before
// chalk-theme.css so the native theme can still override.
import '@chalk/editor-core/styles/host-shell.css';
import './chalk-theme.css';
// Latin subsets only: each css inlines its woff2 as a data URL (build.mjs
// loader), so the full-subset files would bloat the bundle severalfold.
import '@fontsource/ibm-plex-mono/latin-400.css';
import '@fontsource/ibm-plex-mono/latin-400-italic.css';
import '@fontsource/ibm-plex-mono/latin-500.css';
import '@fontsource/ibm-plex-mono/latin-600.css';
import '@fontsource/ibm-plex-mono/latin-700.css';

type InboundHandler = (msg: HostToEditorMessage) => void;

interface ChalkHostBridge {
  /** Swift pushes a host→editor message in. */
  receive(msg: HostToEditorMessage): void;
  /** Swift answers a pending resolveAsset request. */
  resolveAssetReply(id: number, url: string | null): void;
  /** Swift answers a pending list-files request. */
  listFilesReply(id: number, paths: string[] | null): void;
  /** Swift answers a pending read-text request. */
  readTextReply(id: number, text: string | null): void;
  /** Swift answers a pending render-tikz request (null: no TeX here). */
  renderTikzReply(id: number, result: TikzResult | null): void;
}

/**
 * Bridge the native side calls into (clipboard, outline, focus). WebKit's
 * `execCommand('copy')` from `evaluateJavaScript` doesn't reach the pasteboard
 * on Mac Catalyst (no user activation), so Swift reads the selection here and
 * writes `UIPasteboard.general` itself.
 */
interface ChalkEditorBridge {
  /** Text of the current selection (empty if collapsed). */
  copySelection(): string;
  /** Selection text; also deletes the selection (history-tracked). */
  cutSelection(): string;
  /** Outline, cursor line and prose counts for the native outline palette
   *  (pull-on-open). `{items: [], cursorLine: 1}` before `init` lands. */
  getOutlineSnapshot(): OutlineSnapshot;
  /** Jump to a 1-based line: select it, scroll it toward the top, focus. */
  gotoLine(line: number): void;
  /** Restore DOM focus after a native overlay blurred the page: a bare
   *  `becomeFirstResponder` would leave keystrokes on `document.body`. */
  focus(): void;
  /** Turn the debounced `{type: 'outline', items, cursorLine}` push on or
   *  off (transport-internal, like `scroll`). */
  setOutlineSubscription(on: boolean): void;
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers?: Record<string, { postMessage(message: unknown): void }>;
    };
    __chalkHost: ChalkHostBridge;
    __chalkEditor?: ChalkEditorBridge;
    /** Set by the native shell's document-start user script: the host consumes
     *  scroll telemetry (chrome auto-hide). Absent in VS Code. */
    __chalkWantsScrollTelemetry?: boolean;
  }
}

/** Post any payload to the native side; warn (don't throw) if no bridge yet. */
function postToHost(message: unknown): void {
  const handler = window.webkit?.messageHandlers?.chalkHost;
  if (handler) {
    handler.postMessage(message);
  } else {
    console.warn('[chalk] no native host bridge; dropped', message);
  }
}

// --- HostPort over the bridge -------------------------------------------------

let inbound: InboundHandler | null = null;

const port: HostPort = {
  send(msg: EditorToHostMessage): void {
    postToHost(msg);
  },
  onMessage(handler: InboundHandler): () => void {
    inbound = handler;
    return () => {
      if (inbound === handler) inbound = null;
    };
  },
};

// --- Host requests (transport-internal; not part of the 9-message contract)
//
// Request/reply keyed by id: post {type, id, …} and settle when Swift calls
// the matching `…Reply(id, value)`. Id bookkeeping and the hook wrappers live
// in editor-core's host-request.ts, shared with the VS Code host. For
// `workspaceAccess`, Swift walks the document directory; for `renderTikz` it
// runs pdflatex (TikzRenderService).
const requests = createRequestChannel(postToHost);
const { resolveAsset, workspaceAccess, renderTikz } = requestHooks(requests);

// --- The object Swift calls into ---------------------------------------------

window.__chalkHost = {
  receive(msg: HostToEditorMessage): void {
    inbound?.(msg);
  },
  resolveAssetReply(id: number, url: string | null): void {
    requests.settle(id, url);
  },
  listFilesReply(id: number, paths: string[] | null): void {
    requests.settle(id, paths ?? []);
  },
  readTextReply(id: number, text: string | null): void {
    requests.settle(id, text);
  },
  renderTikzReply(id: number, result: TikzResult | null): void {
    requests.settle(id, result);
  },
};

// --- Shell commands ----------------------------------------------------------

/**
 * Commands forwarded over the transport-internal `command` message (native
 * only, so not in editor-core). MIRRORED by `ShellCommand` in
 * mac/ChalkKit/Sources/ChalkKit/ShellCommand.swift: same raw values, same
 * order. Change both (ShellCommandTests pins the Swift half).
 */
export const SHELL_COMMANDS = [
  'save',
  'toggle-outline',
  'toggle-outline-panel',
  'quick-open',
] as const;

export type ShellCommand = (typeof SHELL_COMMANDS)[number];

function postCommand(name: ShellCommand): void {
  postToHost({ type: 'command', name });
}

/** Cmd (no Shift) shortcuts forwarded by the keydown listener in `boot`.
 *  Shift is excluded because Shift+Cmd+O is a shell-only command and must
 *  fall through. A Map, so a key like "constructor" can't hit the prototype. */
const META_COMMANDS: ReadonlyMap<string, ShellCommand> = new Map<string, ShellCommand>([
  ['p', 'toggle-outline'],
  ['P', 'toggle-outline'],
  ['k', 'toggle-outline-panel'],
  ['K', 'toggle-outline-panel'],
  ['o', 'quick-open'],
  ['O', 'quick-open'],
]);

// --- Boot --------------------------------------------------------------------

/**
 * Scroll telemetry for chrome auto-hide (transport-internal). CodeMirror
 * scrolls `.cm-scroller`, not the page, so the native side can't see it.
 * Capture phase on `root` because scroll doesn't bubble and every `init`
 * replaces the scroller; filtered to the scroller so tooltip/autocomplete
 * scrolling doesn't drive the chrome. Throttled to one post per frame.
 */
function attachScrollReporter(root: HTMLElement): void {
  let queued = false;
  root.addEventListener(
    'scroll',
    (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement) || !target.classList.contains('cm-scroller')) return;
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        postToHost({ type: 'scroll', y: target.scrollTop });
      });
    },
    { passive: true, capture: true },
  );
}

function boot(): void {
  const root = document.getElementById('root');
  if (!root) throw new Error('[chalk] #root element missing');
  // mountEditor sends `ready`; the host replies with settings and then
  // `init`. editor-core holds settings that arrive before a view exists.
  const editor = mountEditor({
    root,
    port,
    resolveAsset,
    workspaceAccess,
    // Built beside bundle.js by web/build.mjs; `script-src 'self'` admits it.
    loadMermaid: scriptMermaidLoader('mermaid.js'),
    renderTikz,
    // Outline panel feed; flows only while subscribed
    // (WebEditorSurface.setOutlineSubscription).
    onOutline: (snapshot) => postToHost({ type: 'outline', ...snapshot }),
    // WebKit on Mac Catalyst re-inserts a committed dead key (`^` then `2`
    // gives `^^2`); see editor-core/src/editor/dead-key-commit.ts. Chromium
    // (VS Code) doesn't, so only this host turns it on.
    deadKeyCommitDedupe: true,
  });
  // Opt-in: the native shell injects this flag at document start; without a
  // consumer each scrolled frame would cost an IPC post for nothing.
  if (window.__chalkWantsScrollTelemetry) attachScrollReporter(root);

  window.__chalkEditor = {
    copySelection: () => editor.getSelectionText(),
    cutSelection: () => {
      const text = editor.getSelectionText();
      if (text) editor.replaceSelection('');
      return text;
    },
    getOutlineSnapshot: () => editor.getOutlineSnapshot(),
    gotoLine: (line: number) => editor.gotoLine(line),
    focus: () => editor.focus(),
    setOutlineSubscription: (on: boolean) => editor.setOutlineSubscription(on),
  };

  // On Mac Catalyst the focused WKWebView claims Cmd+S/P/K/O in
  // performKeyEquivalent before the menu or pressesBegan, but still dispatches
  // the JS keydown, so forward them from here. Capture phase, so this runs
  // before editor-core's Mod-p swallow in setup.ts.
  window.addEventListener(
    'keydown',
    (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        postCommand('save');
        return;
      }
      const command = e.metaKey && !e.shiftKey ? META_COMMANDS.get(e.key) : undefined;
      if (command) {
        e.preventDefault();
        postCommand(command);
      }
    },
    true,
  );
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot, { once: true });
} else {
  boot();
}
