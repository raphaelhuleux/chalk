import { EditorState, StateEffect, Transaction } from '@codemirror/state';
import { ViewUpdate } from '@codemirror/view';
import { concealOverridden, isGestureEffect } from './pointer-gesture';

// When a reveal-on-caret plugin rebuilds its decorations, decided once for all
// of them (a pointer-placed caret must not reveal until button release, see
// pointer-gesture.ts). Verdicts:
//   'rebuild'  build a fresh set.
//   'freeze'   a pointer gesture is placing the caret: keep the current set
//              although the state moved past it; `gestureSettled` rebuilds.
//   'keep'     nothing the build reads changed.
// 'freeze' and 'keep' both return the mapped set, but only a frozen set is out
// of sync with the state.

export type RevealVerdict = 'rebuild' | 'freeze' | 'keep';

/** The facts `decide` reads, flattened by `revealSignal` from a Transaction
 *  (StateField consumers) or a ViewUpdate (ViewPlugin consumers). */
export interface RevealSignal {
  readonly docChanged: boolean;
  readonly selectionSet: boolean;
  readonly effects: readonly StateEffect<unknown>[];
  readonly startState: EditorState;
  readonly state: EditorState;
  isUserEvent(event: string): boolean;
}

const NO_EFFECTS: readonly StateEffect<unknown>[] = [];

export function revealSignal(from: Transaction | ViewUpdate): RevealSignal {
  if ('transactions' in from) {
    const trs = from.transactions;
    // Hot path: don't allocate for the common 0/1-transaction cases.
    const effects =
      trs.length === 0
        ? NO_EFFECTS
        : trs.length === 1
          ? (trs[0].effects as readonly StateEffect<unknown>[])
          : trs.flatMap((tr) => tr.effects as readonly StateEffect<unknown>[]);
    return {
      docChanged: from.docChanged,
      selectionSet: from.selectionSet,
      effects,
      startState: from.startState,
      state: from.state,
      isUserEvent: (event) => trs.some((tr) => tr.isUserEvent(event)),
    };
  }
  return {
    docChanged: from.docChanged,
    selectionSet: from.selection != null,
    effects: from.effects,
    startState: from.startState,
    state: from.state,
    isUserEvent: (event) => from.isUserEvent(event),
  };
}

export interface RevealGateOptions {
  /** True when a selection-only change provably can't change this plugin's
   *  set; the gate decides when it is safe to ask. */
  selectionIndependent?: (a: EditorState, b: EditorState) => boolean;
}

export interface RevealGate {
  /** `alsoRebuild`: something else the consumer reads changed (viewport,
   *  parse, preview effect). Forces a rebuild and ends any freeze. */
  decide(signal: RevealSignal, alsoRebuild?: boolean): RevealVerdict;
}

export function createRevealGate(opts: RevealGateOptions = {}): RevealGate {
  // A frozen set doesn't match the previous selection, which the
  // `selectionIndependent` shortcut assumes: skip it until a rebuild resyncs.
  let frozenStale = false;

  return {
    decide(signal, alsoRebuild = false) {
      // Gesture ended or the double-click override flipped: rebuild now.
      if (signal.docChanged || alsoRebuild || signal.effects.some(isGestureEffect)) {
        frozenStale = false;
        return 'rebuild';
      }
      if (!signal.selectionSet) return 'keep';
      // Mid-gesture: the set still renders the unchanged text. Hold it.
      if (signal.isUserEvent('select.pointer')) {
        frozenStale = true;
        return 'freeze';
      }
      if (
        !frozenStale &&
        opts.selectionIndependent &&
        // Flipping the override changes every reveal at once, invisible to
        // per-plugin predicates.
        concealOverridden(signal.startState) === concealOverridden(signal.state) &&
        opts.selectionIndependent(signal.startState, signal.state)
      ) {
        return 'keep';
      }
      frozenStale = false;
      return 'rebuild';
    },
  };
}
