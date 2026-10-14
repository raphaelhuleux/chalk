import { EditorView } from '@codemirror/view';
import { Compartment, StateEffect, Transaction } from '@codemirror/state';
import { createEditor, type EditorActions, type Language } from './editor/setup';
import { extractOutline, type OutlineItem } from './editor/outline';
import { documentStats, type DocumentStats } from './editor/doc-stats';
import type { AssetResolver } from './editor/asset-resolver';
import type { WorkspaceAccess } from './editor/workspace-files';
import type { MermaidLoader } from './editor/md-mermaid-plugin';
import {
  themeCompartment,
  vsCodeTheme,
  sanitizeEditorConfig,
  defaultEditorConfig,
  type EditorConfig,
} from './editor/theme';
import { applyViewMode } from './editor/view-mode';
import { parseHSnips } from './editor/hsnips-parser';
import {
  probeSnapshot,
  probeHidden,
  probeWidgets,
  domVisibleLines,
  expectedVisibleLines,
} from './debug-probe';
import { setSnippets } from './editor/hsnips-plugin';
import { editingModeCompartment, editingModeExtension } from './editor/typewriter-mode';
import { markdownTypesetCompartment, markdownTypesetExtension } from './editor/md-typeset';
import { diffReplace } from './utils/text-diff';
import { docText } from './utils/doc-text';
import {
  setPort,
  clearPort,
  type HostPort,
  type HostToEditorMessage,
  type ThemeColors,
} from './host-port';

// Importing KaTeX's CSS here makes the consuming bundler emit it as a sibling
// stylesheet.
import 'katex/dist/katex.min.css';
import './styles/editor.css';
import './styles/math.css';

export interface MountOptions {
  /** The DOM element the editor mounts into. */
  root: HTMLElement;
  /** The transport that connects this editor to its host. */
  port: HostPort;
  /** Host resolver from an image `src` to a loadable URL. Omitted: images
   *  don't render. */
  resolveAsset?: AssetResolver;
  /** Host access to nearby files for path and citation completion. Omitted:
   *  those completions offer nothing. */
  workspaceAccess?: WorkspaceAccess;
  /** Loads the mermaid renderer on the first ```mermaid fence (usually
   *  `scriptMermaidLoader`). Omitted: those fences render as plain code. */
  loadMermaid?: MermaidLoader;
  /** Outline, cursor line and prose counts, debounced 120ms after each doc or
   *  selection change, only while `setOutlineSubscription(true)` is in force. */
  onOutline?: (snapshot: OutlineSnapshot) => void;
  /** Drop the duplicated prefix Mac Catalyst WebKit inserts on a dead-key
   *  commit (editor/dead-key-commit.ts). Default false: no other host needs it. */
  deadKeyCommitDedupe?: boolean;
}

/** What the outline panel and palette read. `stats` is absent before `init`. */
export interface OutlineSnapshot {
  items: OutlineItem[];
  cursorLine: number;
  stats?: DocumentStats;
}

export interface MountedEditor {
  /** Detach the port listener, destroy the view and release the port. */
  destroy(): void;
  /** Focus at the preserved selection. Before `init` it is a no-op: every
   *  view `init` builds takes focus (createEditor). */
  focus(): void;
  /** Move the cursor to `line` (1-based, clamped), scroll it to the top and
   *  focus. */
  gotoLine(line: number): void;
  /** Outline plus cursor line in one bridge call. `{items: [], cursorLine: 1}`
   *  (no `stats`) before `init`. */
  getOutlineSnapshot(): OutlineSnapshot;
  /** Turn the debounced outline push on or off. Off installs no listener,
   *  so keystrokes pay nothing. */
  setOutlineSubscription(on: boolean): void;
  /** Selected text, ranges joined by newline ('' when collapsed). Read from
   *  state, not the DOM, so it covers lines outside the rendered viewport. */
  getSelectionText(): string;
  /** Replace the selection with `insert` as one undoable transaction (the
   *  native host's cut, bypassing WebKit's clipboard). */
  replaceSelection(insert: string): void;
}

/**
 * Mount a Chalk editor into `root`, driven by `port`, its only host contact.
 * Sends `ready` at once; the host replies with `init`.
 */
export function mountEditor({
  root,
  port,
  resolveAsset,
  workspaceAccess,
  loadMermaid,
  onOutline,
  deadKeyCommitDedupe = false,
}: MountOptions): MountedEditor {
  setPort(port);

  let view: EditorView | null = null;
  let lastKnownText = '';
  // Host text-push generation, echoed on every edit (host-port.ts `epoch`).
  // Undefined for hosts that never stamp (VS Code).
  let hostEpoch: number | undefined;
  let editorConfig: EditorConfig = defaultEditorConfig;
  let currentLanguage: Language = 'md';
  // Kept so hsnips sent before `init` (or between re-inits) reach every new view.
  let lastSnippets: ReturnType<typeof parseHSnips> | null = null;

  // Outline panel push. A compartment so unsubscribing removes the listener
  // outright: the panel is usually closed and it would run on every transaction.
  const outlineCompartment = new Compartment();
  let outlineSubscribed = false;
  let outlineTimer: ReturnType<typeof setTimeout> | null = null;
  const OUTLINE_DEBOUNCE_MS = 120;

  function outlineSnapshot(): OutlineSnapshot {
    if (!view) return { items: [], cursorLine: 1 };
    return {
      items: extractOutline(view.state, currentLanguage),
      cursorLine: view.state.doc.lineAt(view.state.selection.main.head).number,
      stats: documentStats(view.state, currentLanguage),
    };
  }

  function cancelOutlinePush(): void {
    if (outlineTimer !== null) {
      clearTimeout(outlineTimer);
      outlineTimer = null;
    }
  }

  function scheduleOutlinePush(): void {
    cancelOutlinePush();
    outlineTimer = setTimeout(() => {
      outlineTimer = null;
      if (!outlineSubscribed || !view) return;
      onOutline?.(outlineSnapshot());
    }, OUTLINE_DEBOUNCE_MS);
  }

  function outlineExtension() {
    if (!outlineSubscribed) return [];
    return EditorView.updateListener.of((update) => {
      if (update.docChanged || update.selectionSet) scheduleOutlinePush();
    });
  }

  const actions: EditorActions = {
    onContentChange: (content: string) => {
      if (content === lastKnownText) return;
      lastKnownText = content;
      if (hostEpoch === undefined) port.send({ type: 'edit', text: content });
      else port.send({ type: 'edit', text: content, epoch: hostEpoch });
    },
  };

  /** Set `--chalk-syntax-*` on <html>; an unset one falls back to the
   *  HighlightStyle's baked-in hex. */
  function applyThemeColors(colors: ThemeColors): void {
    const docRoot = document.documentElement;
    const set = (key: string, value: string | null | undefined): void => {
      if (value) docRoot.style.setProperty(key, value);
      else docRoot.style.removeProperty(key);
    };
    set('--chalk-syntax-keyword', colors.keyword);
    set('--chalk-syntax-tag', colors.tagName);
    set('--chalk-syntax-comment', colors.comment);
    set('--chalk-syntax-number', colors.number);
    set('--chalk-syntax-atom', colors.atom);
    set('--chalk-syntax-bracket', colors.bracket);
    set('--chalk-syntax-special-variable', colors.specialVariable);
    set('--chalk-syntax-invalid', colors.invalid);
  }

  function handleMessage(msg: HostToEditorMessage): void {
    switch (msg.type) {
      case 'init': {
        if (msg.epoch !== undefined) hostEpoch = msg.epoch;
        const text = normalizeNewlines(msg.text);
        lastKnownText = text;
        currentLanguage = msg.language;
        if (view) {
          view.destroy();
          view = null;
        }
        if (msg.editorConfig !== undefined) {
          editorConfig = sanitizeEditorConfig(msg.editorConfig);
        }
        view = createEditor(root, text, actions, msg.language, {
          config: editorConfig,
          resolveAsset,
          workspaceAccess,
          loadMermaid,
          deadKeyDedupe: deadKeyCommitDedupe,
          extraExtensions: outlineCompartment.of(outlineExtension()),
        });
        if (outlineSubscribed) scheduleOutlinePush();
        // The browser harnesses (Tests/) read `window.__chalkDebugView`,
        // gated on `?debug` or `__chalkDebug = true` set before init (jsdom
        // has no URL). Hosts set neither, so this is inert in production.
        const g = globalThis as Record<string, unknown>;
        if (
          (typeof location !== 'undefined' && /[?&]debug\b/.test(location.search)) ||
          g.__chalkDebug === true
        ) {
          g.__chalkDebugView = view;
          // Reveal-oracle probes (debug-probe.ts), bound through `view` so
          // they follow a re-init.
          const live = (): EditorView => {
            if (!view) throw new Error('no editor view: init has not landed');
            return view;
          };
          g.__chalkDebugProbe = {
            snapshot: () => probeSnapshot(live()),
            hidden: () => probeHidden(live()),
            domLines: () => domVisibleLines(live()),
            widgets: () => probeWidgets(live()),
            // One implementation on both sides of the domLines oracle.
            expectedLines: () =>
              expectedVisibleLines(live().state.doc, probeHidden(live())),
          };
        }
        if (lastSnippets) {
          view.dispatch({ effects: [setSnippets.of(lastSnippets)] });
        }
        return;
      }
      case 'editor-config': {
        const previous = editorConfig;
        editorConfig = sanitizeEditorConfig(msg.config);
        if (!view) return;
        // Reconfigure only what changed: the native host pushes a config on
        // every editing- or view-mode switch.
        const theme = vsCodeTheme(editorConfig);
        const effects: StateEffect<unknown>[] = [];
        if (theme !== vsCodeTheme(previous)) effects.push(themeCompartment.reconfigure(theme));
        if (editorConfig.editingMode !== previous.editingMode) {
          effects.push(
            editingModeCompartment.reconfigure(editingModeExtension(editorConfig.editingMode)),
          );
        }
        if (editorConfig.markdownStyle !== previous.markdownStyle) {
          effects.push(
            markdownTypesetCompartment.reconfigure(markdownTypesetExtension(editorConfig.markdownStyle)),
          );
        }
        if (effects.length > 0) view.dispatch({ effects });
        // The host sends the DEFAULT view mode; Cmd+: sets this editor's live
        // one. Reset only when the default changed, or any push undoes Cmd+:.
        if (editorConfig.viewMode !== previous.viewMode) {
          applyViewMode(view, editorConfig.viewMode);
        }
        return;
      }
      case 'update': {
        // Record the epoch before any early return: the host bumped it even
        // for identical text, and edits echoing the old one are dropped.
        if (msg.epoch !== undefined) hostEpoch = msg.epoch;
        // No view means no `init` yet. An update carries no language and its
        // text predates the init to come (DocumentController.pushText).
        if (!view) return;
        const newText = normalizeNewlines(msg.text);
        // Memoized: the `edit` for this doc already flattened it.
        const oldText = docText(view.state.doc);
        if (newText === oldText) return;
        lastKnownText = newText;
        // Don't replace this with a full-text replace: it collapses the cursor
        // to 0 and loses the viewport (utils/text-diff.ts).
        const { from, to, insert } = diffReplace(oldText, newText);
        // Pin the viewport: a big rewrite resets measured heights to estimates
        // that undershoot math, and the shrunk scrollHeight leaves a blank
        // pane. A dispatch's effects aren't mapped through its own changes, so
        // map the snapshot explicitly (else RangeError on a shrinking update).
        const changes = view.state.changes({ from, to, insert });
        // If the rewrite deletes the viewport's anchor, the mapped snapshot is
        // a stale offset (same blank pane): put the mapped anchor at the top.
        const topBlock = view.lineBlockAtHeight(view.scrollDOM.scrollTop);
        const anchorCovered =
          changes.touchesRange(
            topBlock.from,
            Math.max(topBlock.from, topBlock.to - 1),
          ) === 'cover';
        const scrollEffect = anchorCovered
          ? EditorView.scrollIntoView(changes.mapPos(topBlock.from), { y: 'start' })
          : view.scrollSnapshot().map(changes);
        view.dispatch({
          changes,
          effects: scrollEffect ? [scrollEffect] : [],
          // Host sync: not undoable, and remote so hsnips expansion and
          // mirroring skip it.
          annotations: [
            Transaction.addToHistory.of(false),
            Transaction.remote.of(true),
          ],
        });
        return;
      }
      case 'theme-colors': {
        applyThemeColors(msg.colors);
        return;
      }
      case 'heading-colors': {
        const docRoot = document.documentElement;
        for (const level of [1, 2, 3, 4, 5, 6] as const) {
          const c = msg.colors[level];
          if (c) docRoot.style.setProperty(`--chalk-heading-${level}`, c);
          else docRoot.style.removeProperty(`--chalk-heading-${level}`);
        }
        return;
      }
      case 'hsnips': {
        lastSnippets = parseHSnips(msg.content);
        if (!view) return; // applied by the next `init`
        view.dispatch({
          effects: [setSnippets.of(lastSnippets)],
        });
        return;
      }
    }
  }

  const off = port.onMessage((msg) => {
    if (!isHostMessage(msg)) {
      console.warn('[chalk editor] dropped malformed message', msg);
      return;
    }
    handleMessage(msg);
  });

  port.send({ type: 'ready' });

  return {
    destroy(): void {
      cancelOutlinePush();
      off();
      view?.destroy();
      view = null;
      // Only clears the module port if it is still ours: a later mount on the
      // page may own it.
      clearPort(port);
    },
    focus(): void {
      view?.focus();
    },
    gotoLine(line: number): void {
      if (!view) return;
      const doc = view.state.doc;
      const n = Math.max(1, Math.min(line, doc.lines));
      const pos = doc.line(n).from;
      // y:'start' puts the line at the top (a plain scrollIntoView only nudges
      // to the nearest edge); the margin clears the translucent chrome band.
      view.dispatch({
        selection: { anchor: pos },
        effects: EditorView.scrollIntoView(pos, { y: 'start', yMargin: 100 }),
      });
      view.focus();
    },
    getOutlineSnapshot(): OutlineSnapshot {
      return outlineSnapshot();
    },
    setOutlineSubscription(on: boolean): void {
      if (outlineSubscribed === on) return;
      outlineSubscribed = on;
      if (!on) cancelOutlinePush();
      view?.dispatch({ effects: outlineCompartment.reconfigure(outlineExtension()) });
      // Push now: the listener fires only on the next change, so a panel
      // opened over an idle doc would show no headings until a keystroke.
      if (on) scheduleOutlinePush();
    },
    getSelectionText(): string {
      if (!view) return '';
      const { state } = view;
      return state.selection.ranges
        .filter((r) => !r.empty)
        .map((r) => state.sliceDoc(r.from, r.to))
        .join('\n');
    },
    replaceSelection(insert: string): void {
      if (!view) return;
      view.dispatch(view.state.replaceSelection(insert));
    },
  };
}

/** CM6 stores LF whatever the host sends (VS Code passes a CRLF file's text
 *  through), so host text is compared and diffed in that form. */
function normalizeNewlines(text: string): string {
  return text.includes('\r') ? text.replace(/\r\n?/g, '\n') : text;
}

/** A cast is not a check: validate so a malformed or unknown host message
 *  warns instead of failing silently. */
function isHostMessage(msg: unknown): msg is HostToEditorMessage {
  if (!msg || typeof msg !== 'object') return false;
  const m = msg as Record<string, unknown>;
  switch (m.type) {
    case 'init':
      return typeof m.text === 'string' && (m.language === 'tex' || m.language === 'md');
    case 'update':
      return typeof m.text === 'string';
    case 'theme-colors':
      return typeof m.colors === 'object' && m.colors !== null;
    case 'heading-colors':
      return typeof m.colors === 'object' && m.colors !== null;
    case 'editor-config':
      // Field-level validation happens in sanitizeEditorConfig.
      return typeof m.config === 'object' && m.config !== null;
    case 'hsnips':
      return typeof m.content === 'string';
    default:
      return false;
  }
}
