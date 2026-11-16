/**
 * Shortcut hints while typing math: a list under the caret of the snippets
 * that what was just typed is heading for, with each one's output and
 * trigger. Off unless the host's `editor-config.snippetHints` is 'on'.
 * Spec: docs/specs/2026-11-13-snippet-hints.md.
 */

import {
  Compartment,
  EditorState,
  Extension,
  Facet,
  Prec,
  StateEffect,
  StateField,
  Transaction,
} from '@codemirror/state';
import { EditorView, keymap, showTooltip, type Tooltip } from '@codemirror/view';
import { completionStatus } from '@codemirror/autocomplete';
import type { HSnippet } from './hsnips-parser';
import {
  NAME_ARGUMENT_RE,
  insertSnippetBody,
  isExpansion,
  mathContextFacet,
  passesContextFilter,
  processBody,
  snippetsField,
} from './hsnips-plugin';
import { KaTeXCache } from '../utils/katex-cache';

export interface Hint {
  snippet: HSnippet;
  /** The typed text Tab replaces. */
  from: number;
  to: number;
  /** 'prefix': the start of the trigger was typed. 'name': a `\name` its
   *  output contains was typed. */
  kind: 'prefix' | 'name';
  /** Chars of the trigger already typed (0 for 'name'). */
  typed: number;
  /** The output with every empty stop shown as `\square`, for KaTeX. */
  preview: string;
}

const MAX_HINTS = 8;

/** One-char prefixes that open hints. Any other symbol (`=`, `-`, `,`, `.`) is
 *  ordinary math typing and needs two chars, or every keystroke would open
 *  the list and take Tab from tabout. */
const LEADERS = ';/:';

/** `_`/`^` prefixes need three chars: `x_t` is a subscript, not `_trans`. */
const SCRIPT_MIN = 3;

function minPrefix(first: string): number {
  if (LEADERS.includes(first)) return 1;
  if (first === '_' || first === '^') return SCRIPT_MIN;
  return 2;
}

/** The output as it would appear right after expansion, empty stops boxed. */
export function staticPreview(body: string): string {
  const { text, tabStops } = processBody(body, 0, []);
  let out = text;
  const empty = tabStops.filter((s) => s.index !== 0 && s.from === s.to).sort((a, b) => b.from - a.from);
  for (const s of empty) out = out.slice(0, s.from) + '\\square ' + out.slice(s.from);
  return out.replace(/\\square (?=[^A-Za-z])/g, '\\square').trim();
}

const previewCache = new WeakMap<HSnippet, string>();
function previewOf(snippet: HSnippet): string {
  let p = previewCache.get(snippet);
  if (p === undefined) {
    p = staticPreview(snippet.body);
    previewCache.set(snippet, p);
  }
  return p;
}

/** The longest typed prefix of `snippet`'s trigger ending at the caret, or 0. */
function typedPrefix(snippet: HSnippet, before: string, word: string): number {
  const trigger = snippet.trigger;
  // A Tab-only trigger typed in full is still worth listing: Tab would
  // expand it anyway, and longer triggers may share it (`par`, `part`).
  const longest = snippet.automatic ? trigger.length - 1 : trigger.length;
  for (let k = Math.min(longest, before.length); k >= 1; k--) {
    const prefix = trigger.slice(0, k);
    if (!before.endsWith(prefix)) continue;
    if (k < minPrefix(prefix[0])) return 0;
    const start = before.length - k;
    const prev = before[start - 1] ?? '';
    if (/[A-Za-z0-9]/.test(prefix[0])) {
      // Word start only, and never a letter continuing `\name` (name hints
      // cover that).
      if (/[A-Za-z0-9\\]/.test(prev)) return 0;
    }
    if (snippet.wordboundary && prev !== '' && !/\W/.test(prev)) return 0;
    if (!snippet.inword && !snippet.wordboundary && word !== prefix) return 0;
    if (snippet.beginofline && before.slice(0, start).trim() !== '') return 0;
    return k;
  }
  return 0;
}

/** The hints at the caret, best first. Pure. */
export function computeHints(
  state: EditorState,
  snippets: readonly HSnippet[],
  isInMath: (state: EditorState, pos: number) => boolean,
): Hint[] {
  const sel = state.selection.main;
  if (!sel.empty || snippets.length === 0) return [];
  const pos = sel.head;
  if (!isInMath(state, pos)) return [];
  const line = state.doc.lineAt(pos);
  const before = line.text.slice(0, pos - line.from);
  if (before === '' || NAME_ARGUMENT_RE.test(before)) return [];

  let w = before.length;
  while (w > 0 && !/\s/.test(before[w - 1])) w--;
  const word = before.slice(w);
  const name = /\\[A-Za-z]{2,}$/.exec(before)?.[0];

  const ranked: Array<{ hint: Hint; score: number[] }> = [];
  snippets.forEach((snippet, order) => {
    // Regex snippets: the trigger isn't readable and the output depends on
    // the captures.
    if (!snippet.trigger || snippet.regexp) return;
    if (!passesContextFilter(snippet, state, pos, isInMath)) return;
    const typed = typedPrefix(snippet, before, word);
    if (typed > 0) {
      ranked.push({
        hint: { snippet, from: pos - typed, to: pos, kind: 'prefix', typed, preview: previewOf(snippet) },
        score: [0, -typed, snippet.trigger.length, -snippet.priority, order],
      });
      return;
    }
    if (!name) return;
    const preview = previewOf(snippet);
    const at = commandStartingWith(preview, name);
    if (at < 0) return;
    ranked.push({
      hint: { snippet, from: pos - name.length, to: pos, kind: 'name', typed: 0, preview },
      score: [1, at === 0 ? 0 : 1, snippet.trigger.length, -snippet.priority, order],
    });
  });
  ranked.sort((a, b) => {
    for (let i = 0; i < a.score.length; i++) {
      if (a.score[i] !== b.score[i]) return a.score[i] - b.score[i];
    }
    return 0;
  });
  return ranked.slice(0, MAX_HINTS).map((r) => r.hint);
}

/** Index of the first `\command` in `text` that starts with `name`, or -1. */
function commandStartingWith(text: string, name: string): number {
  const re = /\\[A-Za-z]+/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    if (m[0].startsWith(name)) return m.index;
  }
  return -1;
}

// ── State ───────────────────────────────────────────────────────────

/** The host setting, through `snippetHintsCompartment`. */
export const snippetHintsEnabled = Facet.define<boolean, boolean>({
  combine: (values) => values.some(Boolean),
});
export const snippetHintsCompartment = new Compartment();

interface HintState {
  hints: readonly Hint[];
  selected: number;
}

const EMPTY: HintState = { hints: [], selected: 0 };

const moveSelection = StateEffect.define<number>();
const dismiss = StateEffect.define<null>();

function isTyping(tr: Transaction): boolean {
  return tr.isUserEvent('input.type') || tr.isUserEvent('delete');
}

/**
 * Recomputed only on typing; every other transaction (a caret move, Tab, a
 * host update, an expansion) clears it, so the list never opens on a caret
 * move and Tab after one is still tabout's.
 */
const hintField = StateField.define<HintState>({
  create: () => EMPTY,
  update(value, tr) {
    for (const e of tr.effects) {
      if (e.is(dismiss)) return EMPTY;
      if (e.is(moveSelection)) {
        const n = value.hints.length;
        return n === 0 ? value : { ...value, selected: (value.selected + e.value + n) % n };
      }
    }
    if (!tr.state.facet(snippetHintsEnabled) || completionStatus(tr.state) === 'active') {
      return value === EMPTY ? value : EMPTY;
    }
    if (!tr.docChanged || !isTyping(tr) || isExpansion(tr) || tr.annotation(Transaction.remote)) {
      return tr.docChanged || tr.selection ? EMPTY : value;
    }
    const hints = computeHints(
      tr.state,
      tr.state.field(snippetsField, false) ?? [],
      tr.state.facet(mathContextFacet),
    );
    return hints.length === 0 ? EMPTY : { hints, selected: 0 };
  },
  provide: (field) =>
    showTooltip.compute([field], (state): Tooltip | null => {
      const { hints, selected } = state.field(field);
      if (hints.length === 0) return null;
      return {
        pos: hints[0].to,
        above: false,
        create: (view) => ({ dom: renderHints(view, hints, selected) }),
      };
    }),
});

// ── Commands ────────────────────────────────────────────────────────

function visible(view: EditorView): HintState | null {
  const value = view.state.field(hintField, false);
  if (!value || value.hints.length === 0) return null;
  if (completionStatus(view.state) === 'active') return null;
  return value;
}

function accept(view: EditorView, index: number): boolean {
  const value = visible(view);
  const hint = value?.hints[index];
  if (!hint) return false;
  // A `\name` typed out in full: inserting the same text would only swallow
  // the Tab, so let it reach tabout.
  if (hint.kind === 'name' && plainOutput(hint.snippet) === view.state.sliceDoc(hint.from, hint.to)) {
    view.dispatch({ effects: dismiss.of(null) });
    return false;
  }
  insertSnippetBody(view, hint.from, hint.to, hint.snippet.body);
  return true;
}

function move(delta: number) {
  return (view: EditorView): boolean => {
    const value = visible(view);
    // One row: nothing to choose, so the arrow keeps moving the caret.
    if (!value || value.hints.length < 2) return false;
    view.dispatch({ effects: moveSelection.of(delta) });
    return true;
  };
}

function plainOutput(snippet: HSnippet): string {
  return processBody(snippet.body, 0, []).text;
}

/** Exported for tests. */
export const snippetHintCommands = {
  accept: (view: EditorView) => accept(view, visible(view)?.selected ?? 0),
  down: move(1),
  up: move(-1),
  dismiss: (view: EditorView): boolean => {
    if (!visible(view)) return false;
    view.dispatch({ effects: dismiss.of(null) });
    return true;
  },
};

// Prec.highest: above hsnips' Tab, which a live `dm` session would otherwise
// take. Enter is never bound: it is a new row in `align`.
const hintKeymap = Prec.highest(
  keymap.of([
    { key: 'Tab', run: snippetHintCommands.accept },
    { key: 'ArrowDown', run: snippetHintCommands.down },
    { key: 'ArrowUp', run: snippetHintCommands.up },
    { key: 'Escape', run: snippetHintCommands.dismiss },
  ]),
);

// ── Rendering ───────────────────────────────────────────────────────

const katexCache = new KaTeXCache(300);

function renderHints(view: EditorView, hints: readonly Hint[], selected: number): HTMLElement {
  const dom = document.createElement('div');
  dom.className = 'cm-snippet-hints';
  const list = document.createElement('ul');
  list.setAttribute('role', 'listbox');
  list.setAttribute('aria-label', 'Shortcut hints');
  hints.forEach((hint, i) => {
    const row = document.createElement('li');
    row.setAttribute('role', 'option');
    if (i === selected) row.setAttribute('aria-selected', 'true');

    const preview = document.createElement('span');
    preview.className = 'cm-snippet-hint-preview';
    const html = katexCache.render(hint.preview, false);
    if (html === null) {
      preview.classList.add('cm-snippet-hint-raw');
      preview.textContent = plainOutput(hint.snippet).replace(/\s+/g, ' ');
    } else {
      preview.innerHTML = html;
    }

    const description = document.createElement('span');
    description.className = 'cm-snippet-hint-description';
    // Greek letters describe themselves with their glyph, which the preview
    // already shows.
    const text = hint.snippet.description;
    if ([...text].length > 1) description.textContent = text;

    const trigger = document.createElement('kbd');
    trigger.className = 'cm-snippet-hint-trigger';
    const t = hint.snippet.trigger;
    if (hint.typed > 0) {
      const done = document.createElement('span');
      done.className = 'cm-snippet-hint-typed';
      done.textContent = t.slice(0, hint.typed);
      trigger.append(done, t.slice(hint.typed));
    } else {
      trigger.textContent = t;
    }

    row.append(preview, description, trigger);
    // mousedown, not click: a click would move the caret first and clear the list.
    row.addEventListener('mousedown', (event) => {
      event.preventDefault();
      accept(view, i);
    });
    list.appendChild(row);
  });
  dom.appendChild(list);
  return dom;
}

// ── Extension ───────────────────────────────────────────────────────

export function snippetHintsExtension(mode: 'on' | 'off'): Extension {
  return [snippetHintsCompartment.of(snippetHintsSetting(mode)), hintField, hintKeymap];
}

/** What `snippetHintsCompartment` holds for a setting. */
export function snippetHintsSetting(mode: 'on' | 'off'): Extension {
  return snippetHintsEnabled.of(mode === 'on');
}

/** Internals for unit tests; not public API. */
export const _testing = { hintField };
