/**
 * CodeMirror 6 plugin for HyperSnips-style snippet expansion.
 *
 * Watches every keystroke, matches against loaded snippets (auto-expand
 * only), replaces the trigger text with the snippet body, and manages
 * tab-stop navigation ($1, $2, …, $0).
 *
 * Math context: uses the tex editor's `scanMathRegions` to decide whether
 * the cursor is inside a math region, so `context math(context)`
 * filters work correctly.
 */

import {
  EditorView,
  ViewPlugin,
  ViewUpdate,
  Decoration,
  DecorationSet,
  WidgetType,
  KeyBinding,
} from '@codemirror/view';
import {
  EditorState,
  StateField,
  StateEffect,
  Compartment,
  Extension,
  Transaction,
} from '@codemirror/state';
import type { HSnippet } from './hsnips-parser';
import { scanMathRegions } from './tex-math';

// ── Snippet data ────────────────────────────────────────────────────

/** Effect to update snippets at runtime. */
export const setSnippets = StateEffect.define<HSnippet[]>();

/** StateField that holds the current snippets, updatable via setSnippets effect. */
const snippetsField = StateField.define<HSnippet[]>({
  create: () => [],
  update(snippets, tr) {
    for (const e of tr.effects) {
      if (e.is(setSnippets)) return e.value;
    }
    return snippets;
  },
});

// ── Tab-stop state ──────────────────────────────────────────────────

interface TabStop {
  from: number;
  to: number;
  index: number;
}

interface SnippetSession {
  tabStops: TabStop[];
  currentIndex: number;
}

const setSession = StateEffect.define<SnippetSession | null>();

const sessionField = StateField.define<SnippetSession | null>({
  create: () => null,
  update(session, tr) {
    for (const e of tr.effects) {
      if (e.is(setSession)) return e.value;
    }
    if (!session) return null;
    // Update tab-stop positions through document changes.
    const mapped = session.tabStops.map((ts) => {
      const from = tr.changes.mapPos(ts.from, 1);
      const to = tr.changes.mapPos(ts.to, -1);
      return { ...ts, from, to: Math.max(from, to) };
    });
    return { ...session, tabStops: mapped };
  },
});

// ── Tab-stop decorations (highlight active placeholder) ─────────────

const placeholderMark = Decoration.mark({ class: 'cm-hsnips-placeholder' });

const sessionDecorations = EditorView.decorations.compute(
  [sessionField],
  (state) => {
    const session = state.field(sessionField);
    if (!session) return Decoration.none;
    const current = session.tabStops.find(
      (ts) => ts.index === session.currentIndex,
    );
    if (!current || current.from === current.to) return Decoration.none;
    return Decoration.set([placeholderMark.range(current.from, current.to)]);
  },
);

// ── Math context helper ─────────────────────────────────────────────

function isCursorInMath(state: EditorState, pos: number): boolean {
  const doc = state.doc.toString();
  const regions = scanMathRegions(doc);
  return regions.some((r) => pos >= r.from && pos <= r.to);
}

function passesContextFilter(
  snippet: HSnippet,
  state: EditorState,
  pos: number,
): boolean {
  if (!snippet.contextFilter) return true;
  // Support the standard `math(context)` filter from .hsnips files.
  if (snippet.contextFilter.includes('math')) {
    return isCursorInMath(state, pos);
  }
  // Unknown context filters: skip the snippet to be safe.
  return false;
}

// ── Trigger matching ────────────────────────────────────────────────

interface MatchResult {
  snippet: HSnippet;
  from: number;
  to: number;
  groups: string[];
}

function findMatch(
  state: EditorState,
  snippets: HSnippet[],
): MatchResult | null {
  const pos = state.selection.main.head;
  const line = state.doc.lineAt(pos);
  const lineText = line.text;
  const col = pos - line.from;
  const textUpToCursor = lineText.slice(0, col);

  for (const snippet of snippets) {
    if (!snippet.automatic) continue;
    if (!passesContextFilter(snippet, state, pos)) continue;

    if (snippet.trigger) {
      const trigger = snippet.trigger;

      if (snippet.inword) {
        if (textUpToCursor.endsWith(trigger)) {
          return {
            snippet,
            from: pos - trigger.length,
            to: pos,
            groups: [],
          };
        }
      } else if (snippet.wordboundary) {
        // Check word boundary: character before trigger must be
        // non-word or start of line.
        const startIdx = col - trigger.length;
        if (
          startIdx >= 0 &&
          textUpToCursor.endsWith(trigger) &&
          (startIdx === 0 || /\W/.test(lineText[startIdx - 1]))
        ) {
          return {
            snippet,
            from: pos - trigger.length,
            to: pos,
            groups: [],
          };
        }
      } else {
        // Default: match against the non-whitespace context.
        const contextMatch = textUpToCursor.match(/\S*$/);
        const context = contextMatch ? contextMatch[0] : '';
        if (context === trigger) {
          return {
            snippet,
            from: pos - trigger.length,
            to: pos,
            groups: [],
          };
        }
      }
    } else if (snippet.regexp) {
      const m = snippet.regexp.exec(textUpToCursor);
      if (m) {
        const matchStart = line.from + m.index;
        return {
          snippet,
          from: matchStart,
          to: pos,
          groups: Array.from(m),
        };
      }
    }
  }

  return null;
}

// ── Snippet body processing ─────────────────────────────────────────

interface ProcessedSnippet {
  text: string;
  tabStops: TabStop[];
}

function processBody(
  body: string,
  insertPos: number,
  groups: string[],
): ProcessedSnippet {
  void groups; // regex group substitution intentionally not supported (JS blocks discarded)

  const tabStops: TabStop[] = [];
  let text = '';
  let offset = insertPos;
  let i = 0;

  while (i < body.length) {
    if (body[i] === '$' && i + 1 < body.length) {
      // ${N:default} form
      if (body[i + 1] === '{') {
        const closeIdx = body.indexOf('}', i + 2);
        if (closeIdx !== -1) {
          const inner = body.slice(i + 2, closeIdx);
          const colonIdx = inner.indexOf(':');
          let index: number;
          let defaultText = '';

          if (colonIdx !== -1) {
            index = parseInt(inner.slice(0, colonIdx), 10);
            defaultText = inner.slice(colonIdx + 1);
          } else {
            index = parseInt(inner, 10);
          }

          if (!isNaN(index)) {
            tabStops.push({
              from: offset,
              to: offset + defaultText.length,
              index,
            });
            text += defaultText;
            offset += defaultText.length;
            i = closeIdx + 1;
            continue;
          }
        }
      }
      // $N form (single digit)
      if (/[0-9]/.test(body[i + 1])) {
        const index = parseInt(body[i + 1], 10);
        tabStops.push({ from: offset, to: offset, index });
        i += 2;
        continue;
      }
      // Not a tab stop — literal $
      text += body[i];
      offset++;
      i++;
    } else if (body[i] === '\\' && i + 1 < body.length) {
      // Snippet escape sequences: \$ → $, \} → }, \\ → \
      // Everything else (e.g. \frac, \alpha) passes through as-is.
      const next = body[i + 1];
      if (next === '$' || next === '}' || next === '{' || next === '\\') {
        text += next;
        offset += 1;
        i += 2;
      } else {
        text += body[i] + next;
        offset += 2;
        i += 2;
      }
    } else {
      text += body[i];
      offset++;
      i++;
    }
  }

  // Sort: $1, $2, …, then $0 last.
  tabStops.sort((a, b) => {
    if (a.index === 0) return 1;
    if (b.index === 0) return -1;
    return a.index - b.index;
  });

  return { text, tabStops };
}

// ── Expansion ───────────────────────────────────────────────────────

function expandSnippet(view: EditorView, match: MatchResult): boolean {
  isExpanding = true;
  const { text, tabStops } = processBody(
    match.snippet.body,
    match.from,
    match.groups,
  );

  const effects: StateEffect<unknown>[] = [];

  if (tabStops.length > 0) {
    effects.push(
      setSession.of({
        tabStops,
        currentIndex: tabStops[0].index,
      }),
    );
  }

  view.dispatch({
    changes: { from: match.from, to: match.to, insert: text },
    effects,
    selection:
      tabStops.length > 0
        ? { anchor: tabStops[0].from, head: tabStops[0].to }
        : { anchor: match.from + text.length },
    // Group with previous keystroke so Cmd+Z undoes the whole expansion.
    annotations: [Transaction.addToHistory.of(true)],
  });

  isExpanding = false;
  return true;
}

// ── Auto-expand on document change ──────────────────────────────────

let isExpanding = false;

const autoExpand = EditorView.updateListener.of((update: ViewUpdate) => {
  if (!update.docChanged) return;
  if (isExpanding) return;

  // Detect single-character insertions (keystrokes).
  let isKeystroke = false;
  update.transactions.forEach((tr) => {
    tr.changes.iterChanges((_fromA, _toA, _fromB, _toB, inserted) => {
      if (inserted.length >= 1) isKeystroke = true;
    });
  });

  if (!isKeystroke) return;

  const snippets = update.state.field(snippetsField);
  if (snippets.length === 0) {
    return;
  }

  const match = findMatch(update.state, snippets);
  if (match) {
    // Use queueMicrotask to dispatch after the current update completes
    // but before the next frame — keeps undo grouping tight.
    queueMicrotask(() => expandSnippet(update.view, match));
  }
});

// ── Tab / Shift-Tab keymap ──────────────────────────────────────────

function nextTabStop(view: EditorView): boolean {
  const session = view.state.field(sessionField);
  if (!session) return false;

  const currentIdx = session.tabStops.findIndex(
    (ts) => ts.index === session.currentIndex,
  );
  if (currentIdx === -1 || currentIdx >= session.tabStops.length - 1) {
    // No more stops — exit session, move to $0 if it exists.
    const zero = session.tabStops.find((ts) => ts.index === 0);
    view.dispatch({
      effects: [setSession.of(null)],
      ...(zero ? { selection: { anchor: zero.from, head: zero.to } } : {}),
    });
    return true;
  }

  const next = session.tabStops[currentIdx + 1];
  view.dispatch({
    selection: { anchor: next.from, head: next.to },
    effects: [
      setSession.of({ ...session, currentIndex: next.index }),
    ],
  });
  return true;
}

function prevTabStop(view: EditorView): boolean {
  const session = view.state.field(sessionField);
  if (!session) return false;

  const currentIdx = session.tabStops.findIndex(
    (ts) => ts.index === session.currentIndex,
  );
  if (currentIdx <= 0) return false;

  const prev = session.tabStops[currentIdx - 1];
  view.dispatch({
    selection: { anchor: prev.from, head: prev.to },
    effects: [
      setSession.of({ ...session, currentIndex: prev.index }),
    ],
  });
  return true;
}

function escapeSession(view: EditorView): boolean {
  const session = view.state.field(sessionField);
  if (!session) return false;
  view.dispatch({ effects: [setSession.of(null)] });
  return true;
}

export const hsnipsKeymap: KeyBinding[] = [
  { key: 'Tab', run: nextTabStop },
  { key: 'Shift-Tab', run: prevTabStop },
  { key: 'Escape', run: escapeSession },
];

// ── Theme (placeholder highlight) ───────────────────────────────────

const hsnipsTheme = EditorView.baseTheme({
  '.cm-hsnips-placeholder': {
    backgroundColor: 'rgba(124, 166, 224, 0.25)',
    borderRadius: '2px',
  },
});

// ── Public extension ────────────────────────────────────────────────

export function hsnipsExtension(): Extension {
  return [
    snippetsField,
    sessionField,
    sessionDecorations,
    autoExpand,
    hsnipsTheme,
  ];
}
