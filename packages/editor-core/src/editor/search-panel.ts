import { Command, EditorView, Panel, ViewUpdate, runScopeHandlers } from '@codemirror/view';
import type { EditorState, Text } from '@codemirror/state';
import {
  SearchQuery,
  getSearchQuery,
  setSearchQuery,
  searchPanelOpen,
  openSearchPanel,
  closeSearchPanel,
  replaceNext,
  replaceAll,
} from '@codemirror/search';

/**
 * Compact find/replace card replacing CM6's docked bar, floated top-right by
 * theme.ts's `.cm-panels-top` rule. It owns only the DOM: all state stays in
 * @codemirror/search, so highlighting and the keymap are the stock ones.
 */

// Caps the match scan on huge files; past it the count reads "1000+".
const MATCH_CAP = 1000;

const ICON = {
  search:
    '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" d="M7 2.5a4.5 4.5 0 1 0 2.9 7.96l3.32 3.32M11.5 7A4.5 4.5 0 0 0 7 2.5"/></svg>',
  up: '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M4 10l4-4 4 4"/></svg>',
  down: '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M4 6l4 4 4-4"/></svg>',
  close:
    '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M4 4l8 8M12 4l-8 8"/></svg>',
  expand:
    '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" d="M6 4l4 4-4 4"/></svg>',
  replace:
    '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" d="M3 5h6a3 3 0 0 1 0 6H6M5 3L3 5l2 2"/></svg>',
};

function button(
  className: string,
  label: string,
  content: string,
  onClick: (e: MouseEvent) => void,
  isText = false,
): HTMLButtonElement {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = className;
  b.tabIndex = -1; // keep Tab flowing between the two text inputs only
  b.title = label;
  b.setAttribute('aria-label', label);
  if (isText) b.textContent = content;
  else b.innerHTML = content;
  b.addEventListener('mousedown', (e) => e.preventDefault()); // don't steal focus
  b.addEventListener('click', onClick);
  return b;
}

interface Matches {
  matches: { from: number; to: number }[];
  capped: boolean;
}

function collectMatches(state: EditorState, query: SearchQuery): Matches {
  const matches: { from: number; to: number }[] = [];
  if (!query.valid) return { matches, capped: false };
  const cursor = query.getCursor(state);
  let next = cursor.next();
  while (!next.done) {
    matches.push({ from: next.value.from, to: next.value.to });
    if (matches.length >= MATCH_CAP) return { matches, capped: true };
    next = cursor.next();
  }
  return { matches, capped: false };
}

/** Whether two queries find the same matches (the replace text does not). */
function sameMatches(a: SearchQuery, b: SearchQuery): boolean {
  return (
    a.search === b.search &&
    a.caseSensitive === b.caseSensitive &&
    a.regexp === b.regexp &&
    a.wholeWord === b.wholeWord &&
    a.literal === b.literal
  );
}

class ChalkSearchPanel implements Panel {
  readonly dom: HTMLFormElement;
  readonly top = true;

  private readonly findInput: HTMLInputElement;
  private readonly replaceInput: HTMLInputElement;
  private readonly countEl: HTMLSpanElement;
  private readonly caseBtn: HTMLButtonElement;
  private readonly regexBtn: HTMLButtonElement;
  private readonly expandBtn: HTMLButtonElement;
  private readonly replaceRow: HTMLDivElement;

  private replaceOpen = false;
  // Stable anchor, so typing extends the query in place instead of walking
  // forward one match per keystroke.
  private searchFrom = 0;
  private refreshTimer: ReturnType<typeof setTimeout> | null = null;
  // Shared by the several scans a keystroke or navigation triggers, until the
  // query or doc changes.
  private lastScan: { doc: Text; query: SearchQuery; result: Matches } | null = null;

  constructor(private readonly view: EditorView) {
    const q = getSearchQuery(view.state);
    this.searchFrom = view.state.selection.main.from;

    this.dom = document.createElement('form');
    this.dom.className = 'chalk-find';
    this.dom.onsubmit = (e) => e.preventDefault();
    // Run CM6's search-panel keymap while focus is in our inputs.
    this.dom.addEventListener('keydown', (e) => {
      if (runScopeHandlers(view, e, 'search-panel')) e.preventDefault();
    });

    const findRow = document.createElement('div');
    findRow.className = 'chalk-find__row';

    const findIcon = document.createElement('span');
    findIcon.className = 'chalk-find__icon';
    findIcon.innerHTML = ICON.search;

    this.findInput = document.createElement('input');
    this.findInput.className = 'chalk-find__input';
    this.findInput.setAttribute('main-field', 'true');
    this.findInput.setAttribute('placeholder', 'Find');
    this.findInput.setAttribute('aria-label', 'Find');
    this.findInput.value = q.search;
    this.findInput.addEventListener('input', () => this.commit(true));
    // searchKeymap doesn't bind plain Enter; the stock panel did it itself.
    this.findInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        this.navigate(e.shiftKey ? -1 : 1);
      }
    });

    this.countEl = document.createElement('span');
    this.countEl.className = 'chalk-find__count';

    this.caseBtn = button(
      'chalk-find__toggle',
      'Match case',
      'Aa',
      () => this.toggle('caseSensitive'),
      true,
    );
    this.regexBtn = button(
      'chalk-find__toggle',
      'Regular expression',
      '.*',
      () => this.toggle('regexp'),
      true,
    );
    this.expandBtn = button('chalk-find__toggle chalk-find__expand', 'Toggle replace', ICON.expand, () =>
      this.setReplaceOpen(!this.replaceOpen),
    );

    const nav = document.createElement('span');
    nav.className = 'chalk-find__nav';
    nav.append(
      button('chalk-find__icon-btn', 'Previous match (⇧⏎)', ICON.up, () => this.navigate(-1)),
      button('chalk-find__icon-btn', 'Next match (⏎)', ICON.down, () => this.navigate(1)),
    );

    const closeBtn = button('chalk-find__icon-btn chalk-find__close', 'Close (Esc)', ICON.close, () =>
      closeSearchPanel(view),
    );

    findRow.append(
      findIcon,
      this.findInput,
      this.countEl,
      nav,
      this.caseBtn,
      this.regexBtn,
      this.expandBtn,
      closeBtn,
    );

    this.replaceRow = document.createElement('div');
    this.replaceRow.className = 'chalk-find__row chalk-find__replace';

    const replaceIcon = document.createElement('span');
    replaceIcon.className = 'chalk-find__icon';
    replaceIcon.innerHTML = ICON.replace;

    this.replaceInput = document.createElement('input');
    this.replaceInput.className = 'chalk-find__input';
    this.replaceInput.setAttribute('placeholder', 'Replace');
    this.replaceInput.setAttribute('aria-label', 'Replace');
    this.replaceInput.value = q.replace;
    this.replaceInput.addEventListener('input', () => this.commit(false));
    this.replaceInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        replaceNext(view);
      }
    });

    const replaceActions = document.createElement('span');
    replaceActions.className = 'chalk-find__replace-actions';
    replaceActions.append(
      button('chalk-find__text-btn', 'Replace', 'Replace', () => replaceNext(view), true),
      button('chalk-find__text-btn', 'Replace all', 'All', () => replaceAll(view), true),
    );

    this.replaceRow.append(replaceIcon, this.replaceInput, replaceActions);

    this.dom.append(findRow, this.replaceRow);

    this.syncToggles(q);
    this.setReplaceOpen(false);
  }

  mount() {
    // openSearchPanel only focuses the input on a re-open; first focus is ours.
    this.findInput.focus();
    this.findInput.select();
    this.refreshCount();
  }

  /** Dispatch the inputs' query, keeping the current flags (`flip` inverts one). */
  private setQuery(flip?: 'caseSensitive' | 'regexp'): SearchQuery {
    const current = getSearchQuery(this.view.state);
    const query = new SearchQuery({
      search: this.findInput.value,
      replace: this.replaceInput.value,
      caseSensitive: flip === 'caseSensitive' ? !current.caseSensitive : current.caseSensitive,
      regexp: flip === 'regexp' ? !current.regexp : current.regexp,
      wholeWord: current.wholeWord,
    });
    this.view.dispatch({ effects: setSearchQuery.of(query) });
    return query;
  }

  private commit(fromFindInput: boolean) {
    const query = this.setQuery();
    if (fromFindInput) this.selectFromAnchor(query);
    this.refreshCount(query);
  }

  private toggle(flag: 'caseSensitive' | 'regexp') {
    const query = this.setQuery(flag);
    this.syncToggles(query);
    this.selectFromAnchor(query);
    this.refreshCount(query);
    this.findInput.focus();
  }

  private matchesFor(query: SearchQuery): Matches {
    const { state } = this.view;
    const last = this.lastScan;
    if (last && last.doc === state.doc && sameMatches(last.query, query)) return last.result;
    const result = collectMatches(state, query);
    this.lastScan = { doc: state.doc, query, result };
    return result;
  }

  private selectFromAnchor(query: SearchQuery) {
    if (!query.valid || !query.search) return;
    const { matches } = this.matchesFor(query);
    if (!matches.length) return;
    this.selectMatch(matches.find((m) => m.from >= this.searchFrom) ?? matches[0]);
  }

  private selectMatch(target: { from: number; to: number }) {
    this.view.dispatch({
      selection: { anchor: target.from, head: target.to },
      effects: EditorView.scrollIntoView(target.from, { y: 'center' }),
      userEvent: 'select.search',
    });
  }

  private navigate(dir: 1 | -1) {
    const query = getSearchQuery(this.view.state);
    if (!query.valid || !query.search) return;
    const { matches } = this.matchesFor(query);
    if (!matches.length) return;
    const sel = this.view.state.selection.main;
    let idx: number;
    if (dir === 1) {
      idx = matches.findIndex((m) => m.from > sel.from);
      if (idx === -1) idx = 0; // wrap to first
    } else {
      idx = -1;
      for (let i = matches.length - 1; i >= 0; i--) {
        if (matches[i].from < sel.from) {
          idx = i;
          break;
        }
      }
      if (idx === -1) idx = matches.length - 1; // wrap to last
    }
    const target = matches[idx];
    this.searchFrom = target.from;
    this.selectMatch(target);
    // update() doesn't recount on selection-only changes.
    this.refreshCount();
    this.findInput.focus();
  }

  private setReplaceOpen(open: boolean) {
    this.replaceOpen = open;
    this.dom.classList.toggle('chalk-find--replacing', open);
    this.expandBtn.classList.toggle('chalk-find__expand--open', open);
    this.expandBtn.setAttribute('aria-expanded', String(open));
  }

  private syncToggles(query: SearchQuery) {
    this.caseBtn.classList.toggle('chalk-find__toggle--on', query.caseSensitive);
    this.caseBtn.setAttribute('aria-pressed', String(query.caseSensitive));
    this.regexBtn.classList.toggle('chalk-find__toggle--on', query.regexp);
    this.regexBtn.setAttribute('aria-pressed', String(query.regexp));
  }

  private refreshCount(query = getSearchQuery(this.view.state)) {
    this.dom.classList.toggle('chalk-find--invalid', Boolean(query.search) && !query.valid);
    if (!query.search) {
      this.countEl.textContent = '';
      return;
    }
    if (!query.valid) {
      this.countEl.textContent = '!';
      this.countEl.title = 'Invalid regular expression';
      return;
    }
    this.countEl.title = '';
    const { matches, capped } = this.matchesFor(query);
    const total = matches.length;
    if (total === 0) {
      this.countEl.textContent = 'No results';
      return;
    }
    const sel = this.view.state.selection.main;
    const current = matches.findIndex((m) => m.from === sel.from && m.to === sel.to) + 1;
    const totalLabel = capped ? `${MATCH_CAP}+` : String(total);
    this.countEl.textContent = current ? `${current}/${totalLabel}` : totalLabel;
  }

  update(update: ViewUpdate) {
    // Pick up query changes made elsewhere without clobbering typing.
    const q = getSearchQuery(this.view.state);
    if (document.activeElement !== this.findInput && this.findInput.value !== q.search)
      this.findInput.value = q.search;
    if (document.activeElement !== this.replaceInput && this.replaceInput.value !== q.replace)
      this.replaceInput.value = q.replace;
    this.syncToggles(q);
    // A recount walks the whole doc: do it at once on a query change,
    // debounced on doc changes, never on caret moves.
    const queryChanged = update.transactions.some((tr) =>
      tr.effects.some((e) => e.is(setSearchQuery)),
    );
    if (queryChanged) {
      this.cancelScheduledRefresh();
      this.refreshCount(q);
    } else if (update.docChanged) {
      this.scheduleRefresh();
    }
  }

  private scheduleRefresh() {
    if (this.refreshTimer !== null) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = null;
      this.refreshCount();
    }, 100);
  }

  private cancelScheduledRefresh() {
    if (this.refreshTimer !== null) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = null;
    }
  }

  destroy() {
    this.cancelScheduledRefresh();
  }
}

export function chalkSearchPanel(view: EditorView): Panel {
  return new ChalkSearchPanel(view);
}

/** Cmd+F opens or closes the panel; setup.ts binds it in the `search-panel`
 *  scope too, so it works from the find input. */
export const toggleSearchPanel: Command = (view) => {
  if (searchPanelOpen(view.state)) return closeSearchPanel(view);
  return openSearchPanel(view);
};
