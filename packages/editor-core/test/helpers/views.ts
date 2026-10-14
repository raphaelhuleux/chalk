import { ensureSyntaxTree } from '@codemirror/language';
import { EditorSelection } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import type { AssetResolver } from '../../src/editor/asset-resolver';
import { createEditor, type Language } from '../../src/editor/setup';
import { defaultEditorConfig, type EditorConfig } from '../../src/editor/theme';
import type { WorkspaceAccess } from '../../src/editor/workspace-files';
import type { MermaidLoader } from '../../src/editor/md-mermaid-plugin';
import type { EditorToHostMessage, HostPort, HostToEditorMessage } from '../../src/host-port';
import { parsed } from './force-parse';

/**
 * One mounted-view factory for the jsdom suite.
 *
 * Fifty-odd test files each grew their own `mount`/`makeView`/`makeTexView`,
 * all assembling the same five steps in slightly different order: clear the
 * body, attach a parent, `createEditor`, finish the parse, park the caret.
 * The differences that mattered are the options below; everything else was
 * copy-paste drift.
 *
 * Attaching `parent` to `document.body` is not optional: CM6 only builds its
 * DOM for a view whose parent is in the document, so a detached parent makes
 * every decoration assertion vacuous.
 */
export interface ViewOptions {
  /** Caret position after mount. `'end'` is the document end. Omit to leave
   *  the selection where `createEditor` put it (position 0) with no dispatch. */
  cursor?: number | 'end';
  /** Shorthand for `{ ...defaultEditorConfig, viewMode }`. */
  viewMode?: EditorConfig['viewMode'];
  /** Full config override; `viewMode` above still wins if both are given. */
  config?: EditorConfig;
  resolveAsset?: AssetResolver;
  workspaceAccess?: WorkspaceAccess;
  loadMermaid?: MermaidLoader;
  /** Run `ensureSyntaxTree` over the whole document after mounting, on top of
   *  the `parsed()` forced parse, so decorations rebuild against a full tree. */
  ensureTree?: boolean;
  /** Wipe `document.body` first (default) so a previous view's DOM can't be
   *  picked up by a document-wide query. Pass `false` when the test compares
   *  two views that must both stay mounted. */
  clearBody?: boolean;
  onContentChange?: (content: string) => void;
  /** Turn on the Catalyst dead-key commit dedupe (off in the app by default,
   *  see src/editor/dead-key-commit.ts). */
  deadKeyCommitDedupe?: boolean;
}

const registry: EditorView[] = [];

function mountView(doc: string, language: Language, opts: ViewOptions = {}): EditorView {
  if (opts.clearBody !== false) document.body.innerHTML = '';
  const parent = document.createElement('div');
  document.body.appendChild(parent);
  const config =
    opts.viewMode === undefined
      ? (opts.config ?? defaultEditorConfig)
      : { ...(opts.config ?? defaultEditorConfig), viewMode: opts.viewMode };
  const view = parsed(
    createEditor(parent, doc, { onContentChange: opts.onContentChange ?? (() => {}) }, language, {
      config,
      resolveAsset: opts.resolveAsset,
      workspaceAccess: opts.workspaceAccess,
      loadMermaid: opts.loadMermaid,
      deadKeyDedupe: opts.deadKeyCommitDedupe,
    }),
  );
  if (opts.ensureTree) ensureSyntaxTree(view.state, view.state.doc.length, 5000);
  if (opts.cursor !== undefined) {
    const at = opts.cursor === 'end' ? view.state.doc.length : opts.cursor;
    view.dispatch({ selection: EditorSelection.cursor(at) });
  }
  registry.push(view);
  return view;
}

/** A mounted `.tex` editor. */
export function texView(doc: string, opts?: ViewOptions): EditorView {
  return mountView(doc, 'tex', opts);
}

/** A mounted `.md` editor. */
export function mdView(doc: string, opts?: ViewOptions): EditorView {
  return mountView(doc, 'md', opts);
}

/** Same, with the language as a value — for the tests that run one body over
 *  both languages. */
export function langView(doc: string, language: Language, opts?: ViewOptions): EditorView {
  return mountView(doc, language, opts);
}

/** Destroy every view this module handed out. Call from `afterEach`. */
export function destroyViews(): void {
  for (const v of registry.splice(0)) v.destroy();
}

export interface MockPort {
  port: HostPort;
  /** Everything the editor sent to the host, in order. */
  sent: EditorToHostMessage[];
  /** Deliver a host→editor message. */
  push: (m: HostToEditorMessage) => void;
  /** True while an inbound handler is registered: `onMessage` sets it, and the
   *  unsubscribe it returned clears it again. */
  readonly hasHandler: boolean;
}

/** A `HostPort` that records what the editor sends and replays what the test
 *  pushes. Seven files had their own byte-identical copy. */
export function mockPort(): MockPort {
  const sent: EditorToHostMessage[] = [];
  let handler: ((m: HostToEditorMessage) => void) | null = null;
  const port: HostPort = {
    send: (m) => sent.push(m),
    onMessage: (h) => {
      handler = h;
      return () => {
        handler = null;
      };
    },
  };
  return {
    port,
    sent,
    push: (m: HostToEditorMessage) => handler?.(m),
    get hasHandler() {
      return handler !== null;
    },
  };
}
