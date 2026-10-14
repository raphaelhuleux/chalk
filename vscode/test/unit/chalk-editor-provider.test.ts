import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Drives the real ChalkEditorProvider against a fake of the VS Code surface it
 * touches. The fake document reproduces the three behaviours of the real API
 * that the webview → TextDocument edit path depends on:
 *
 *   - `workspace.applyEdit` captures the document version when it is CALLED
 *     (ExtHostWorkspace converts the edit synchronously) and the main thread
 *     rejects it — the promise resolves `false` — if the document moved on
 *     before the edit landed ("… has changed in the meantime").
 *   - `onDidChangeTextDocument` fires before the applyEdit promise resolves
 *     (the model-changed RPC is sent ahead of the applyEdit reply).
 *   - TextModel.validateRange widens a range end that falls inside a surrogate
 *     pair to cover the whole pair, and inserted text takes the model's EOL.
 */
const fake = vi.hoisted(() => {
  type Listener<T> = (e: T) => void;
  const emitter = <T>() => {
    const listeners = new Set<Listener<T>>();
    return {
      event: (l: Listener<T>) => {
        listeners.add(l);
        return { dispose: () => listeners.delete(l) };
      },
      fire: (e: T) => {
        for (const l of [...listeners]) l(e);
      },
    };
  };

  class Position {
    constructor(
      readonly line: number,
      readonly character: number,
    ) {}
  }
  class Range {
    readonly start: Position;
    readonly end: Position;
    constructor(a: Position | number, b: Position | number, c?: number, d?: number) {
      if (typeof a === 'number') {
        this.start = new Position(a, b as number);
        this.end = new Position(c as number, d as number);
      } else {
        this.start = a;
        this.end = b as Position;
      }
    }
  }
  class WorkspaceEdit {
    readonly edits: { uri: unknown; range: Range; newText: string }[] = [];
    replace(uri: unknown, range: Range, newText: string): void {
      this.edits.push({ uri, range, newText });
    }
  }
  const EndOfLine = { LF: 1, CRLF: 2 } as const;

  const isHigh = (c: number) => c >= 0xd800 && c <= 0xdbff;

  class FakeDocument {
    version = 1;
    readonly uri = {
      scheme: 'untitled',
      fsPath: '/doc.tex',
      toString: () => 'untitled:/doc.tex',
    };
    constructor(
      public text: string,
      public eol: number = EndOfLine.LF,
    ) {}
    private get sep(): string {
      return this.eol === EndOfLine.CRLF ? '\r\n' : '\n';
    }
    private get lines(): string[] {
      return this.text.split(this.sep);
    }
    getText(): string {
      return this.text;
    }
    get lineCount(): number {
      return this.lines.length;
    }
    // ExtHostDocumentData.positionAt: an offset inside an EOL clamps to the
    // end of its line.
    positionAt(offset: number): Position {
      const lines = this.lines;
      let rest = Math.max(0, offset);
      for (let i = 0; i < lines.length; i++) {
        if (rest <= lines[i].length || i === lines.length - 1) {
          return new Position(i, Math.min(rest, lines[i].length));
        }
        rest -= lines[i].length + this.sep.length;
        if (rest < 0) return new Position(i, lines[i].length);
      }
      return new Position(0, 0);
    }
    offsetAt(pos: Position): number {
      const lines = this.lines;
      if (pos.line >= lines.length) return this.text.length;
      let offset = 0;
      for (let i = 0; i < pos.line; i++) offset += lines[i].length + this.sep.length;
      return offset + Math.min(pos.character, lines[pos.line].length);
    }
    /** A change made outside this panel (another editor, another extension). */
    externalEdit(newText: string): void {
      this.text = newText;
      this.version++;
      changeEmitter.fire({ document: this, contentChanges: [{}] });
    }
    /** A save or revert-to-clean: an event with no content change. */
    fireDirtyFlagChange(): void {
      changeEmitter.fire({ document: this, contentChanges: [] });
    }
    /** What the main thread does with one text edit. */
    apply(range: Range, insert: string): void {
      let from = this.offsetAt(range.start);
      let to = this.offsetAt(range.end);
      const splits = (o: number) => o > 0 && isHigh(this.text.charCodeAt(o - 1));
      if (from === to) {
        if (splits(from)) from = to = from - 1;
      } else {
        if (splits(from)) from--;
        if (splits(to) && to < this.text.length) to++;
      }
      const normalized = insert.replace(/\r\n|\r|\n/g, this.sep);
      this.text = this.text.slice(0, from) + normalized + this.text.slice(to);
      this.version++;
    }
  }

  const changeEmitter = emitter<{ document: FakeDocument; contentChanges: unknown[] }>();
  const state = {
    document: null as FakeDocument | null,
    appliedEdits: [] as { range: Range; newText: string }[],
    applyEdit: async (edit: WorkspaceEdit): Promise<boolean> => {
      const doc = state.document!;
      const version = doc.version;
      await new Promise((r) => setTimeout(r, 1)); // the IPC round-trip
      if (doc.version !== version) return false;
      for (const e of edit.edits) {
        state.appliedEdits.push(e);
        doc.apply(e.range, e.newText);
      }
      changeEmitter.fire({ document: doc, contentChanges: edit.edits });
      return true;
    },
  };

  const noopEvent = () => ({ dispose: () => {} });
  const api = {
    Position,
    Range,
    WorkspaceEdit,
    EndOfLine,
    ColorThemeKind: { Light: 1, Dark: 2, HighContrast: 3, HighContrastLight: 4 },
    Uri: {
      joinPath: (u: { fsPath: string }, ...parts: string[]) => ({
        fsPath: [u.fsPath, ...parts].join('/'),
        toString: () => [u.fsPath, ...parts].join('/'),
      }),
      file: (p: string) => ({ fsPath: p, toString: () => `file://${p}` }),
    },
    RelativePattern: class {},
    workspace: {
      getConfiguration: () => ({ get: () => undefined }),
      onDidChangeTextDocument: changeEmitter.event,
      onDidChangeConfiguration: noopEvent,
      createFileSystemWatcher: () => ({
        onDidChange: noopEvent,
        onDidCreate: noopEvent,
        onDidDelete: noopEvent,
        dispose: () => {},
      }),
      applyEdit: (edit: WorkspaceEdit) => state.applyEdit(edit),
    },
    window: {
      activeColorTheme: { kind: 2 },
      onDidChangeActiveColorTheme: noopEvent,
      showErrorMessage: () => Promise.resolve(undefined),
    },
    extensions: { all: [] },
    env: { openExternal: () => Promise.resolve(true) },
  };

  return { api, state, FakeDocument, EndOfLine };
});

vi.mock('vscode', () => fake.api);

import { ChalkEditorProvider } from '../../src/extension/chalk-editor-provider';
import { minimalReplace, toDocumentEol } from '../../src/extension/document-sync';
import type { LanguageProfile } from '../../src/extension/languages/types';

const profile: LanguageProfile = {
  id: 'tex',
  viewType: 'chalk.texEditor',
  settingsLanguageId: 'latex',
  themeScopeCandidates: {
    keyword: [],
    tagName: [],
    comment: [],
    number: [],
    atom: [],
    bracket: [],
    specialVariable: [],
    invalid: [],
  },
  loadHsnips: () => null,
};

interface Posted {
  type: string;
  text?: string;
}

/** One Chalk panel on `text`, by default already past the webview's `ready`. */
async function openPanel(
  text: string,
  eol: number = fake.EndOfLine.LF,
  { ready = true }: { ready?: boolean } = {},
) {
  const document = new fake.FakeDocument(text, eol);
  fake.state.document = document;
  fake.state.appliedEdits = [];

  const posted: Posted[] = [];
  let onMessage: (msg: unknown) => Promise<void> | void = () => {};
  let onDispose: () => void = () => {};
  const viewState = new Set<() => void>();
  const panel = {
    visible: true,
    webview: {
      options: {},
      html: '',
      cspSource: 'vscode-resource:',
      asWebviewUri: (u: unknown) => u,
      postMessage: (msg: Posted) => {
        posted.push(msg);
        return Promise.resolve(true);
      },
      onDidReceiveMessage: (l: typeof onMessage) => {
        onMessage = l;
        return { dispose: () => {} };
      },
    },
    onDidChangeViewState: (l: () => void) => {
      viewState.add(l);
      return { dispose: () => viewState.delete(l) };
    },
    onDidDispose: (l: () => void) => {
      onDispose = l;
      return { dispose: () => {} };
    },
  };

  const context = { extensionUri: { fsPath: '/ext' } };
  const provider = new ChalkEditorProvider(context as never, profile, {
    appendLine: () => {},
  } as never);
  await provider.resolveCustomTextEditor(document as never, panel as never, {} as never);
  if (ready) {
    await onMessage({ type: 'ready' });
    await settle();
  }

  return {
    document,
    posted,
    /** A message from the webview; not awaited, like VS Code's dispatch. */
    send: (msg: unknown) => void onMessage(msg),
    ready: () => onMessage({ type: 'ready' }),
    updates: () => posted.filter((m) => m.type === 'update').map((m) => m.text),
    becomeVisible: () => viewState.forEach((l) => l()),
    dispose: () => onDispose(),
  };
}

/** Let every queued round-trip land. */
async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) await new Promise((r) => setTimeout(r, 2));
}

let panel: Awaited<ReturnType<typeof openPanel>> | null = null;
beforeEach(() => {
  panel = null;
});
afterEach(() => {
  panel?.dispose();
});

describe('ChalkEditorProvider: webview edits reach the TextDocument', () => {
  it('lands both edits when an hsnips expansion posts right behind its keystroke', async () => {
    panel = await openPanel('x\n');
    // The trigger keystroke, then the expansion the auto-snippet dispatches
    // from its update listener: two `edit`s before either applyEdit returns.
    panel.send({ type: 'edit', text: 'x\nfr' });
    panel.send({ type: 'edit', text: 'x\n\\frac{}{}' });
    await settle();
    // Before the fix the second applyEdit carried a stale version and was
    // rejected, and the first one's change event was swallowed, so a save
    // here wrote the unexpanded trigger.
    expect(panel.document.getText()).toBe('x\n\\frac{}{}');
    expect(panel.updates()).toEqual([]);
  });

  it('applies only the latest of a burst of edits', async () => {
    panel = await openPanel('');
    panel.send({ type: 'edit', text: 'a' });
    panel.send({ type: 'edit', text: 'ab' });
    panel.send({ type: 'edit', text: 'abc' });
    await settle();
    expect(panel.document.getText()).toBe('abc');
    // The first edit is in flight when the other two arrive; only the newest
    // of those is worth sending.
    expect(fake.state.appliedEdits).toHaveLength(2);
  });

  it('forwards a change made elsewhere while its own edit is in flight', async () => {
    panel = await openPanel('one\n');
    panel.send({ type: 'edit', text: 'one\ntwo' });
    await settle();
    panel.document.externalEdit('zero\none\ntwo');
    await settle();
    expect(panel.updates()).toEqual(['zero\none\ntwo']);
  });

  it('resyncs the webview when VS Code rejects an edit', async () => {
    panel = await openPanel('base');
    panel.send({ type: 'edit', text: 'base!' });
    panel.send({ type: 'edit', text: 'base!!' });
    // Another editor changes the document before the first edit lands, so it
    // is rejected as stale.
    panel.document.externalEdit('other base');
    await settle();
    expect(panel.document.getText()).toBe('other base');
    // The webview ends on the document's text, not on an edit that was
    // computed against a buffer the document never had.
    expect(panel.updates().at(-1)).toBe('other base');
  });

  it('does not post the echo of its own edit back to the webview', async () => {
    panel = await openPanel('a\n');
    panel.send({ type: 'edit', text: 'a\nb' });
    await settle();
    expect(panel.document.getText()).toBe('a\nb');
    expect(panel.updates()).toEqual([]);
  });
});

describe('ChalkEditorProvider: edits replace only the changed slice', () => {
  it('sends a minimal range, not the whole document', async () => {
    panel = await openPanel('hello world\nsecond line\n');
    panel.send({ type: 'edit', text: 'hello brave world\nsecond line\n' });
    await settle();
    expect(panel.document.getText()).toBe('hello brave world\nsecond line\n');
    expect(fake.state.appliedEdits).toHaveLength(1);
    const [edit] = fake.state.appliedEdits;
    expect(edit.newText).toBe('brave ');
    expect([edit.range.start.line, edit.range.start.character]).toEqual([0, 6]);
    expect([edit.range.end.line, edit.range.end.character]).toEqual([0, 6]);
  });

  it('diffs a CRLF document against the engine text in CRLF form', async () => {
    panel = await openPanel('a\r\nb\r\n', fake.EndOfLine.CRLF);
    panel.send({ type: 'edit', text: 'a\nX\nb\n' });
    await settle();
    expect(panel.document.getText()).toBe('a\r\nX\r\nb\r\n');
    const [edit] = fake.state.appliedEdits;
    expect(edit.newText).toBe('X\r\n');
    expect([edit.range.start.line, edit.range.start.character]).toEqual([1, 0]);
  });

  it('treats LF engine text equal to a CRLF document as no change', async () => {
    panel = await openPanel('a\r\nb\r\n', fake.EndOfLine.CRLF);
    panel.send({ type: 'edit', text: 'a\nb\n' });
    await settle();
    expect(fake.state.appliedEdits).toEqual([]);
  });

  it('never cuts a surrogate pair in half', async () => {
    // 😀 and 😁 share their high surrogate. A code-unit diff would replace
    // only the low one, and VS Code widens such a range to the whole pair
    // while inserting the lone low surrogate.
    panel = await openPanel('x😀y');
    panel.send({ type: 'edit', text: 'x😁y' });
    await settle();
    expect(panel.document.getText()).toBe('x😁y');
  });
});

describe('ChalkEditorProvider: host → webview pushes', () => {
  it('lets init alone carry changes made before the webview was ready', async () => {
    panel = await openPanel('v1', fake.EndOfLine.LF, { ready: false });
    panel.document.externalEdit('v2');
    panel.document.externalEdit('v3');
    await panel.ready();
    await settle();
    expect(panel.posted.find((m) => m.type === 'init')?.text).toBe('v3');
    expect(panel.updates()).toEqual([]);
  });

  it('forwards nothing for a change event without content changes', async () => {
    panel = await openPanel('text');
    panel.document.fireDirtyFlagChange();
    await settle();
    expect(panel.updates()).toEqual([]);
  });

  it('does not repost the whole document when the panel becomes visible', async () => {
    panel = await openPanel('text');
    panel.becomeVisible();
    await settle();
    expect(panel.updates()).toEqual([]);
  });
});

describe('minimalReplace', () => {
  it('replaces only the differing middle', () => {
    expect(minimalReplace('abcdef', 'abXYef')).toEqual({ from: 2, to: 4, insert: 'XY' });
  });

  it('handles pure insertions and deletions at either end', () => {
    expect(minimalReplace('abc', 'abcd')).toEqual({ from: 3, to: 3, insert: 'd' });
    expect(minimalReplace('abc', 'zabc')).toEqual({ from: 0, to: 0, insert: 'z' });
    expect(minimalReplace('abc', 'ac')).toEqual({ from: 1, to: 2, insert: '' });
  });

  it('keeps a boundary out of a surrogate pair on either side', () => {
    // Shared high surrogate: the prefix must stop before it.
    expect(minimalReplace('x😀y', 'x😁y')).toEqual({ from: 1, to: 3, insert: '😁' });
    // Shared low surrogate: the suffix must stop after it.
    expect(minimalReplace('\uD83D\uDE00', '\uD83E\uDE00')).toEqual({
      from: 0,
      to: 2,
      insert: '\uD83E\uDE00',
    });
  });

  it('keeps a boundary out of a CRLF', () => {
    const { from, to, insert } = minimalReplace('a\r\nb', 'a\rX\nb');
    expect(from).toBe(1);
    expect(to).toBe(3);
    expect(insert).toBe('\rX\n');
  });
});

describe('toDocumentEol', () => {
  it('converts engine text to a CRLF document\'s line endings', () => {
    expect(toDocumentEol('a\nb\n', fake.EndOfLine.CRLF as never)).toBe('a\r\nb\r\n');
    expect(toDocumentEol('a\r\nb', fake.EndOfLine.CRLF as never)).toBe('a\r\nb');
  });

  it('leaves LF text for an LF document untouched', () => {
    expect(toDocumentEol('a\nb', fake.EndOfLine.LF as never)).toBe('a\nb');
    expect(toDocumentEol('a\r\nb', fake.EndOfLine.LF as never)).toBe('a\nb');
  });
});
