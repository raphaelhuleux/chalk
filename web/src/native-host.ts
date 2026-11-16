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
  /** Clear the AI marks in the selection, or all of them with none. */
  acceptAiMarks(): void;
  /** Drop the AI text in the selection (or all of it), restoring what it
   *  deleted. */
  rejectAiMarks(): void;
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
  'next-tab',
  'previous-tab',
  'accept-ai-marks',
  'reject-ai-marks',
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
 * `wheel` marks a scroll the reader drove: a jump to a line or a reflow also
 * moves `scrollTop`, and must not hide the tabs
 * (docs/issues/2026-10-31-tabs-hide-without-scrolling.md).
 * Mid-wheel, CM6 swapping estimated line heights for measured ones moves
 * `scrollTop` against the wheel (~300px down while wheeling up through
 * display math), so only a frame that moved the wheel's way counts.
 */
function attachScrollReporter(root: HTMLElement): void {
  const wheelWindowMs = 200;
  let lastWheel = -Infinity;
  /** Sign of the latest vertical wheel delta; +1 scrolls toward the end. */
  let wheelDirection = 0;
  root.addEventListener(
    'wheel',
    (event) => {
      lastWheel = performance.now();
      if (event.deltaY !== 0) wheelDirection = Math.sign(event.deltaY);
    },
    { passive: true, capture: true },
  );
  let queued = false;
  let wheel = false;
  /** The last posted frame, to tell which way this one moved. */
  let lastScroller: HTMLElement | null = null;
  let lastY = 0;
  root.addEventListener(
    'scroll',
    (event) => {
      const target = event.target;
      if (!(target instanceof HTMLElement) || !target.classList.contains('cm-scroller')) return;
      // Read here, not in the frame callback, which a busy page can delay past the window.
      wheel ||= performance.now() - lastWheel < wheelWindowMs;
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        const y = target.scrollTop;
        // A fresh scroller has no previous frame to take a direction from.
        const withWheel = target === lastScroller && Math.sign(y - lastY) === wheelDirection;
        postToHost({ type: 'scroll', y, wheel: wheel && withWheel });
        lastScroller = target;
        lastY = y;
        wheel = false;
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
    // For the host's store (DocumentController.editor(_:didChangeAiMarks:text:)).
    onAiMarks: (marks, text) => postToHost({ type: 'ai-marks', marks, text }),
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
    acceptAiMarks: () => editor.acceptAiMarks(),
    rejectAiMarks: () => editor.rejectAiMarks(),
  };

  // The focused WKWebView claims key equivalents before the menu and hands back
  // only those the page leaves alone, so forward the shell's keys from here.
  // Capture phase, so this runs before editor-core's Mod-p swallow in setup.ts.
  window.addEventListener(
    'keydown',
    (e: KeyboardEvent) => {
      if (e.metaKey && e.shiftKey && (e.key === 'Enter' || e.key === 'Backspace')) {
        e.preventDefault();
        postCommand(e.key === 'Enter' ? 'accept-ai-marks' : 'reject-ai-marks');
        return;
      }
      if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'S')) {
        e.preventDefault();
        postCommand('save');
        return;
      }
      // Ctrl+Tab never reached the menu from a focused editor.
      if (e.ctrlKey && !e.metaKey && !e.altKey && e.key === 'Tab') {
        e.preventDefault();
        postCommand(e.shiftKey ? 'previous-tab' : 'next-tab');
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
