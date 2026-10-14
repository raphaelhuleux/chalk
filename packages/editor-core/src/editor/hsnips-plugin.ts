/**
 * HyperSnips-style snippet expansion. `A`-flagged snippets expand as you
 * type; the rest expand on Tab when no tab-stop session is active.
 * Language-agnostic: the math test comes in through `HsnipsOptions`.
 *
 * Mirror groups: a repeated index (`\frac{$1}{$1}`) has its first occurrence
 * as the leader (decorated, receives the cursor); `mirrorFilter` copies every
 * leader edit into the others.
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
  Facet,
  Transaction,
  ChangeSpec,
  Annotation,
} from '@codemirror/state';
import { acceptCompletion, completionStatus, startCompletion } from '@codemirror/autocomplete';
import type { HSnippet } from './hsnips-parser';

// ── Snippet data ────────────────────────────────────────────────────

/** Replaces the loaded snippets at runtime. */
export const setSnippets = StateEffect.define<HSnippet[]>();

const snippetsField = StateField.define<HSnippet[]>({
  create: () => [],
  update(snippets, tr) {
    for (const e of tr.effects) {
      if (e.is(setSnippets)) return e.value;
    }
    return snippets;
  },
});

/** A facet so the static `hsnipsKeymap` can evaluate `math(context)`
 *  during manual Tab expansion. */
type MathContextFn = (state: EditorState, pos: number) => boolean;
const mathContextFacet = Facet.define<MathContextFn, MathContextFn>({
  combine: (values) => values[0] ?? (() => false),
});

// ── Tab-stop state ──────────────────────────────────────────────────

interface TabStop {
  from: number;
  to: number;
  index: number;
}

interface SnippetSession {
  /** Sorted $1, $2, …, then $0; same-index entries (mirrors) stay in
   *  document order so the first is the leader. */
  tabStops: TabStop[];
  currentIndex: number;
}

const setSession = StateEffect.define<SnippetSession | null>();

/** Tags the mirror filter's own echo so it doesn't re-fire on it. */
const isMirrorEcho = Annotation.define<boolean>();

function findGroupLeader(stops: TabStop[], index: number): TabStop | null {
  for (const s of stops) {
    if (s.index === index) return s;
  }
  return null;
}

function uniqueIndices(stops: TabStop[]): number[] {
  const out: number[] = [];
  for (const s of stops) {
    if (!out.includes(s.index)) out.push(s.index);
  }
  return out;
}

const sessionField = StateField.define<SnippetSession | null>({
  create: () => null,
  update(session, tr) {
    for (const e of tr.effects) {
      if (e.is(setSession)) return e.value;
    }
    if (!session) return null;
    // The active group absorbs insertions at its edges (typing into an empty
    // stop fills it); other stops exclude them, so `$1$2` doesn't hand $1's
    // text to $2.
    const mapped = session.tabStops.map((ts) => {
      const inclusive = ts.index === session.currentIndex;
      const from = tr.changes.mapPos(ts.from, inclusive ? -1 : 1);
      const to = tr.changes.mapPos(ts.to, inclusive ? 1 : -1);
      return { ...ts, from, to: Math.max(from, to) };
    });
    // End the session once the cursor leaves the span of all stops, or the
    // stale ranges drift over whatever text now occupies them.
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
    const leader = findGroupLeader(session.tabStops, session.currentIndex);
    if (!leader || leader.from === leader.to) return Decoration.none;
    return Decoration.set([placeholderMark.range(leader.from, leader.to)]);
  },
);

// ── Mirror filter ───────────────────────────────────────────────────
//
// An edit touching the leader's range copies the leader's new text into
// every mirror. A transactionFilter, so the mirror changes ride in the same
// transaction and downstream extensions see one clean position mapping.

function buildMirrorChanges(
  tr: Transaction,
  session: SnippetSession,
): ChangeSpec[] | null {
  const groupStops = session.tabStops.filter(
    (s) => s.index === session.currentIndex,
  );
  if (groupStops.length <= 1) return null;
  const leader = groupStops[0];
  const mirrors = groupStops.slice(1);

  let touched = false;
  tr.changes.iterChanges((fromA, toA) => {
    if (toA < leader.from) return;
    if (fromA > leader.to) return;
    touched = true;
  });
  if (!touched) return null;

  // -1/+1 so insertions exactly at the boundary count as leader content.
  const newLeaderFrom = tr.changes.mapPos(leader.from, -1);
  const newLeaderTo = tr.changes.mapPos(leader.to, 1);
  if (newLeaderTo < newLeaderFrom) return null;
  const newText = tr.newDoc.sliceString(newLeaderFrom, newLeaderTo);

  return mirrors.map((m) => {
    const from = tr.changes.mapPos(m.from, -1);
    const to = tr.changes.mapPos(m.to, 1);
    return { from, to, insert: newText };
  });
}

const mirrorFilter = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged) return tr;
  if (tr.annotation(isMirrorEcho)) return tr;
  // Host-sync updates (Transaction.remote, from mount.ts) are authoritative:
  // echoing one that intersects the leader would corrupt the text.
  if (tr.annotation(Transaction.remote)) return tr;
  const session = tr.startState.field(sessionField, false);
  if (!session) return tr;

  const changes = buildMirrorChanges(tr, session);
  if (!changes || changes.length === 0) return tr;
  return [
    tr,
    { changes, sequential: true, annotations: isMirrorEcho.of(true) },
  ];
});

// ── Context filter ──────────────────────────────────────────────────

/**
 * Counts math-context evaluations so the perf test can assert the
 * per-`findMatch` memo holds: one per keystroke, not one per snippet.
 */
let contextEvals = 0;
export function __contextEvalCount(): number {
  return contextEvals;
}
export function __resetContextEvalCount(): void {
  contextEvals = 0;
}

const loggedUnknownContexts = new Set<string>();

function passesContextFilter(
  snippet: HSnippet,
  state: EditorState,
  pos: number,
  isInMathContext: (state: EditorState, pos: number) => boolean,
): boolean {
  if (!snippet.contextFilter) return true;
  // Exact match, not substring, so `notmath(context)` or `math2(context)`
  // don't route through the math gate.
  if (snippet.contextFilter === 'math(context)') {
    return isInMathContext(state, pos);
  }
  if (snippet.contextFilter === '!math(context)') {
    return !isInMathContext(state, pos);
  }
  // Unknown filter: warn once so users notice their snippets vanished.
  if (!loggedUnknownContexts.has(snippet.contextFilter)) {
    loggedUnknownContexts.add(snippet.contextFilter);
    console.warn(
      `[chalk hsnips] unknown context filter ${JSON.stringify(snippet.contextFilter)} — snippet skipped. Only "math(context)" and "!math(context)" are supported.`,
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

/**
 * Circuit breaker for catastrophic-backtracking user regexes (`(a+)+b`),
 * which run on every keystroke. The cost grows exponentially per typed char,
 * so tripping at 100ms disables the snippet before the 20s keystroke.
 */
const slowSnippets = new WeakSet<HSnippet>();
const SLOW_EXEC_MS = 100;

function findMatch(
  state: EditorState,
  snippets: HSnippet[],
  isInMathContext: (state: EditorState, pos: number) => boolean,
  manual = false,
): MatchResult | null {
  const pos = state.selection.main.head;
  const line = state.doc.lineAt(pos);
  const lineText = line.text;
  const col = pos - line.from;
  const textUpToCursor = lineText.slice(0, col);
  // The math test depends only on (state, pos): evaluate it at most once,
  // not once per math-gated snippet (~230 in the bundled set).
  let mathCtx: boolean | undefined;
  const countedContext = (s: EditorState, p: number) => {
    if (mathCtx === undefined) {
      contextEvals++;
      mathCtx = isInMathContext(s, p);
    }
    return mathCtx;
  };
  // The whitespace-delimited word a plain literal trigger must equal.
  let word: string | undefined;
  const wordBeforeCursor = (): string => {
    if (word === undefined) {
      let i = col;
      while (i > 0 && !/\s/.test(textUpToCursor[i - 1])) i--;
      word = textUpToCursor.slice(i);
    }
    return word;
  };

  for (const snippet of snippets) {
    if (!manual && !snippet.automatic) continue;
    if (!passesContextFilter(snippet, state, pos, countedContext)) continue;

    if (snippet.trigger) {
      const trigger = snippet.trigger;
      // `b` flag: only whitespace may precede the trigger (UltiSnips' rule),
      // so `b` snippets still fire inside an indented environment.
      if (snippet.beginofline && textUpToCursor.slice(0, col - trigger.length).trim() !== '')
        continue;

      const startIdx = col - trigger.length;
      const hit = snippet.inword
        ? textUpToCursor.endsWith(trigger)
        : snippet.wordboundary
          ? startIdx >= 0 &&
            textUpToCursor.endsWith(trigger) &&
            (startIdx === 0 || /\W/.test(lineText[startIdx - 1]))
          : wordBeforeCursor() === trigger;
      if (hit) return { snippet, from: pos - trigger.length, to: pos, groups: [] };
    } else if (snippet.regexp) {
      if (slowSnippets.has(snippet)) continue;
      const t0 = Date.now();
      const m = snippet.regexp.exec(textUpToCursor);
      if (Date.now() - t0 > SLOW_EXEC_MS) {
        slowSnippets.add(snippet);
        console.warn(
          `[chalk hsnips] snippet regex \`${snippet.regexpSource ?? snippet.trigger}\` took over ${SLOW_EXEC_MS}ms to match — disabled for this session (likely catastrophic backtracking).`,
        );
        continue;
      }
      // An all-optional pattern (`[0-9]*`) matches empty at the caret on any
      // line and would re-insert the body on every keystroke.
      if (m && m[0].length > 0) {
        if (snippet.beginofline && textUpToCursor.slice(0, m.index).trim() !== '') continue;
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
  trimmedCaptures?: Set<number>,
): ProcessedSnippet {
  // Only regex matches have groups, so `#N` stays literal in literal-trigger
  // snippets, where it is likely a real LaTeX macro argument.
  const hasCaptures = groups.length > 0;

  const tabStops: TabStop[] = [];
  let text = '';
  let offset = insertPos;
  let i = 0;

  while (i < body.length) {
    if (body[i] === '$' && i + 1 < body.length) {
      if (body[i + 1] === '{') {
        // Balance nested braces so `${1:\frac{a}{b}}` isn't cut at the first
        // `}`; a backslash escapes the next char.
        let depth = 1;
        let k = i + 2;
        while (k < body.length) {
          const c = body[k];
          if (c === '\\' && k + 1 < body.length) {
            k += 2;
            continue;
          }
          if (c === '{') depth++;
          else if (c === '}' && --depth === 0) break;
          k++;
        }
        const closeIdx = depth === 0 ? k : -1;
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
      // $N: take the full digit run so $10 isn't $1 plus a literal 0.
      if (/[0-9]/.test(body[i + 1])) {
        let j = i + 2;
        while (j < body.length && /[0-9]/.test(body[j])) j++;
        const index = parseInt(body.slice(i + 1, j), 10);
        tabStops.push({ from: offset, to: offset, index });
        i = j;
        continue;
      }
      text += body[i];
      offset++;
      i++;
    } else if (body[i] === '\\' && i + 1 < body.length) {
      // Escapes \$ \{ \} \\ drop the backslash; \frac etc. pass through.
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
    } else if (
      hasCaptures &&
      body[i] === '#' &&
      i + 1 < body.length &&
      /[0-9]/.test(body[i + 1])
    ) {
      let j = i + 1;
      while (j < body.length && /[0-9]/.test(body[j])) j++;
      const index = parseInt(body.slice(i + 1, j), 10);
      const raw = groups[index] ?? '';
      const value = trimmedCaptures?.has(index) ? raw.trim() : raw;
      text += value;
      offset += value.length;
      i = j;
    } else {
      text += body[i];
      offset++;
      i++;
    }
  }

  // $1, $2, … then $0; same-index stops in document order so the leader is
  // deterministic (it drives the decoration and the mirror echo).
  tabStops.sort((a, b) => {
    if (a.index === 0 && b.index !== 0) return 1;
    if (b.index === 0 && a.index !== 0) return -1;
    if (a.index !== b.index) return a.index - b.index;
    return a.from - b.from;
  });

  return { text, tabStops };
}

// ── Expansion ───────────────────────────────────────────────────────

let isExpanding = false;

function expandSnippet(view: EditorView, match: MatchResult): boolean {
  return insertProcessedBody(
    view,
    match.from,
    match.to,
    match.snippet.body,
    match.groups,
    match.snippet.trimmedCaptures,
    // CM6's typing userEvent, so one Cmd+Z undoes expansion and keystroke.
    'input.type',
  );
}

/**
 * Expand an hsnips `body` over [from, to) with tab stops, for callers with no
 * trigger. Completions apply through here so the editor has ONE tab-stop
 * model (CM6's `snippetCompletion` would put a second session on Tab).
 * `\\` in the body emits one backslash, so a LaTeX row break needs four.
 *
 * Tagged `input.complete`: `input.type` would keep the applying popup open
 * over stale options, which Tab would accept again.
 */
export function insertSnippetBody(
  view: EditorView,
  from: number,
  to: number,
  body: string,
): boolean {
  insertProcessedBody(view, from, to, body, [], undefined, 'input.complete');
  offerCompletionsAtStop(view);
  return true;
}

function insertProcessedBody(
  view: EditorView,
  from: number,
  to: number,
  body: string,
  groups: string[],
  trimmedCaptures: Set<number> | undefined,
  userEvent: 'input.type' | 'input.complete',
): boolean {
  isExpanding = true;
  const { text, tabStops } = processBody(body, from, groups, trimmedCaptures);

  const effects: StateEffect<unknown>[] = [];

  // A lone $0 starts no session: the cursor lands there and the next Tab
  // reaches tabout / manual expansion instead of a no-op exit.
  const indices = uniqueIndices(tabStops);
  const onlyFinalStop = indices.length === 1 && indices[0] === 0;

  if (tabStops.length > 0 && !onlyFinalStop) {
    effects.push(
      setSession.of({
        tabStops,
        currentIndex: tabStops[0].index,
      }),
    );
  }

  const firstLeader = tabStops.length > 0 ? tabStops[0] : null;

  try {
    view.dispatch({
      changes: { from, to, insert: text },
      effects,
      selection: firstLeader
        ? { anchor: firstLeader.from, head: firstLeader.to }
        : { anchor: from + text.length },
      userEvent,
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
    // Host-sync updates (Transaction.remote) are not keystrokes.
    if (update.transactions.some((tr) => tr.annotation(Transaction.remote)))
      return;

    // Only single-char insertions: pastes must not auto-expand (as upstream
    // HyperSnips). Tab expansion goes through manualExpand instead.
    let isKeystroke = false;
    update.transactions.forEach((tr) => {
      tr.changes.iterChanges((_fromA, _toA, _fromB, _toB, inserted) => {
        if (inserted.length === 1) isKeystroke = true;
      });
    });

    if (!isKeystroke) return;

    const snippets = update.state.field(snippetsField);
    if (snippets.length === 0) {
      return;
    }

    const match = findMatch(update.state, snippets, isInMathContext);
    if (match) {
      // Synchronous (not rAF) so it shares the keystroke's history group;
      // `isExpanding` blocks re-entry.
      expandSnippet(update.view, match);
    }
  });
}

// ── Tab / Shift-Tab keymap ──────────────────────────────────────────

/**
 * Offer completions at the stop just landed on. `activateOnTyping` only fires
 * on `input.type`, which a tab-stop move and an `insertSnippetBody` lack, so
 * e.g. the figure snippet's `![]()` slot would never open the file list.
 * Unconditional: sources return null when there is nothing to offer, and CM6
 * won't complete over a placeholder's non-empty selection.
 */
function offerCompletionsAtStop(view: EditorView): void {
  if (view.state.selection.main.empty) startCompletion(view);
}

/** Tab with no session: the only way non-`A` snippets expand. Returns false
 *  on no match so Tab falls through to completion/tabout/indent
 *  (hsnipsKeymap is registered before them). */
function manualExpand(view: EditorView): boolean {
  const snippets = view.state.field(snippetsField, false);
  if (!snippets || snippets.length === 0) return false;
  const isInMathContext = view.state.facet(mathContextFacet);
  const match = findMatch(view.state, snippets, isInMathContext, true);
  if (!match) return false;
  return expandSnippet(view, match);
}

function nextTabStop(view: EditorView): boolean {
  const session = view.state.field(sessionField);
  if (!session) return manualExpand(view);
  // An open popup takes Tab first: a stop like `\ref{$1}` offers labels on
  // arrival (offerCompletionsAtStop), and Tab picks the highlighted one.
  if (completionStatus(view.state) === 'active' && acceptCompletion(view)) return true;

  const indices = uniqueIndices(session.tabStops);
  const curPos = indices.indexOf(session.currentIndex);
  if (curPos === -1 || curPos >= indices.length - 1) {
    // Past the last stop: end the session at $0 if there is one.
    const zero = findGroupLeader(session.tabStops, 0);
    view.dispatch({
      effects: [setSession.of(null)],
      ...(zero ? { selection: { anchor: zero.from, head: zero.to } } : {}),
    });
    offerCompletionsAtStop(view);
    return true;
  }

  const nextIdx = indices[curPos + 1];
  const nextLeader = findGroupLeader(session.tabStops, nextIdx);
  if (!nextLeader) return false;
  view.dispatch({
    selection: { anchor: nextLeader.from, head: nextLeader.to },
    effects: [setSession.of({ ...session, currentIndex: nextIdx })],
  });
  offerCompletionsAtStop(view);
  return true;
}

function prevTabStop(view: EditorView): boolean {
  const session = view.state.field(sessionField);
  if (!session) return false;

  const indices = uniqueIndices(session.tabStops);
  const curPos = indices.indexOf(session.currentIndex);
  if (curPos <= 0) return false;

  const prevIdx = indices[curPos - 1];
  const prevLeader = findGroupLeader(session.tabStops, prevIdx);
  if (!prevLeader) return false;
  view.dispatch({
    selection: { anchor: prevLeader.from, head: prevLeader.to },
    effects: [setSession.of({ ...session, currentIndex: prevIdx })],
  });
  offerCompletionsAtStop(view);
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

interface HsnipsOptions {
  /** Evaluates the `math(context)` filter. setup.ts passes each language's
   *  math test wrapped in `snippetMathContext` (which excludes `\text{}`). */
  isInMathContext: (state: EditorState, pos: number) => boolean;
}

export function hsnipsExtension(opts: HsnipsOptions): Extension {
  return [
    snippetsField,
    sessionField,
    sessionDecorations,
    mirrorFilter,
    mathContextFacet.of(opts.isInMathContext),
    autoExpandFor(opts.isInMathContext),
    hsnipsTheme,
  ];
}

// ── Testing surface ─────────────────────────────────────────────────
// Internals for unit tests; not public API.

export const _testing = {
  processBody,
  uniqueIndices,
  findGroupLeader,
  sessionField,
  setSession,
  mirrorFilter,
  snippetsField,
  findMatch,
  manualExpand,
};
