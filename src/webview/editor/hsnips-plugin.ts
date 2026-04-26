/**
 * CodeMirror 6 plugin for HyperSnips-style snippet expansion.
 *
 * Watches every keystroke, matches against loaded snippets (auto-expand
 * only), replaces the trigger text with the snippet body, and manages
 * tab-stop navigation ($1, $2, …, $0).
 *
 * Math context: accepts an `isInMathContext` callback via `HsnipsOptions`
 * so the engine is language-agnostic. Tex passes `isInMathContextTex`;
 * markdown will pass a lezer-tree query in Phase 6.
 */

import {
  EditorView,
  ViewUpdate,
  Decoration,
  KeyBinding,
} from '@codemirror/view';
import {
  EditorState,
  StateField,
  StateEffect,
  Extension,
} from '@codemirror/state';
import type { HSnippet } from './hsnips-parser';

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
    // Kill the session if the cursor wandered outside the bounding box of
    // every tab stop — covers click-away, arrow-out-then-type, or typing
    // far from the active placeholder. Without this, mapPos silently
    // drifts the stale ranges across whatever now occupies them.
    let min = Infinity;
    let max = -Infinity;
    for (const s of mapped) {
      if (s.from < min) min = s.from;
      if (s.to > max) max = s.to;
    }
    const head = tr.newSelection.main.head;
    if (head < min || head > max) return null;
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

// ── Context filter ──────────────────────────────────────────────────

const loggedUnknownContexts = new Set<string>();

function passesContextFilter(
  snippet: HSnippet,
  state: EditorState,
  pos: number,
  isInMathContext: (state: EditorState, pos: number) => boolean,
): boolean {
  if (!snippet.contextFilter) return true;
  // Standard HyperSnips filter — exact match, not substring, so user
  // contexts like notmath(context) or math2(context) don't accidentally
  // route through the math gate.
  if (snippet.contextFilter === 'math(context)') {
    return isInMathContext(state, pos);
  }
  // Unknown context filters: warn once per filter so users notice their
  // snippets vanished, then reject to be safe.
  if (!loggedUnknownContexts.has(snippet.contextFilter)) {
    loggedUnknownContexts.add(snippet.contextFilter);
    console.warn(
      `[chalk hsnips] unknown context filter ${JSON.stringify(snippet.contextFilter)} — snippet skipped. Only "math(context)" is supported.`,
    );
  }
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
  isInMathContext: (state: EditorState, pos: number) => boolean,
): MatchResult | null {
  const pos = state.selection.main.head;
  const line = state.doc.lineAt(pos);
  const lineText = line.text;
  const col = pos - line.from;
  const textUpToCursor = lineText.slice(0, col);

  for (const snippet of snippets) {
    if (!snippet.automatic) continue;
    if (!passesContextFilter(snippet, state, pos, isInMathContext)) continue;

    if (snippet.trigger) {
      const trigger = snippet.trigger;
      // `b` flag: trigger must sit at column 0.
      if (snippet.beginofline && col !== trigger.length) continue;

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
        // `b` flag: regex match must start at column 0.
        if (snippet.beginofline && m.index !== 0) continue;
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
      // $N form — scan the full digit run so $10, $11, … parse correctly
      // (the original single-digit slice would split $10 into $1 + literal 0).
      if (/[0-9]/.test(body[i + 1])) {
        let j = i + 2;
        while (j < body.length && /[0-9]/.test(body[j])) j++;
        const index = parseInt(body.slice(i + 1, j), 10);
        tabStops.push({ from: offset, to: offset, index });
        i = j;
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

let isExpanding = false;

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

  try {
    view.dispatch({
      changes: { from: match.from, to: match.to, insert: text },
      effects,
      selection:
        tabStops.length > 0
          ? { anchor: tabStops[0].from, head: tabStops[0].to }
          : { anchor: match.from + text.length },
      // Tag with the same userEvent CM6 uses for typing so the history
      // extension groups this expansion with the trigger keystroke and
      // a single Cmd+Z undoes both.
      userEvent: 'input.type',
    });
  } finally {
    isExpanding = false;
  }
  return true;
}

// ── Auto-expand on document change ──────────────────────────────────

function autoExpandFor(
  isInMathContext: (state: EditorState, pos: number) => boolean,
) {
  return EditorView.updateListener.of((update: ViewUpdate) => {
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

    const match = findMatch(update.state, snippets, isInMathContext);
    if (match) {
      // Synchronous dispatch (not rAF) so the expansion lands in the
      // same history group as the keystroke — see expandSnippet.
      // Re-entry into this listener is blocked by `isExpanding`.
      expandSnippet(update.view, match);
    }
  });
}

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

export interface HsnipsOptions {
  /** Returns true when `pos` lies inside a math region in `state`. The
   *  hsnips engine uses this to evaluate the `math(context)` filter from
   *  .hsnips files. Tex passes `isInMathContextTex` from `tex-math.ts`;
   *  md passes a lezer-tree query for `InlineMath`/`DisplayMath` nodes. */
  isInMathContext: (state: EditorState, pos: number) => boolean;
}

export function hsnipsExtension(opts: HsnipsOptions): Extension {
  return [
    snippetsField,
    sessionField,
    sessionDecorations,
    autoExpandFor(opts.isInMathContext),
    hsnipsTheme,
  ];
}
