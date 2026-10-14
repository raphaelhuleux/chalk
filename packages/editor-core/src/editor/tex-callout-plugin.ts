import { Extension } from '@codemirror/state';
import {
  LABELS,
  UNNUMBERED,
  CalloutOpen,
  CalloutOptions,
  ScanCallouts,
  LineCollapsed,
  makeCachedScanner,
  makeCalloutField,
  makeFenceStopKeymap,
} from './callout-core';
import { isPreviewMode } from './view-mode';

// LaTeX surface syntax for callouts (`\begin{theorem}[title]`); everything
// else is shared via callout-core. Recognised envs must stay disjoint from
// tex-math-incremental's MATH_ENVIRONMENTS, so `equation`/`align` are never
// callouts. A starred env is the same type, unnumbered.

// `\begin{env}[title]`, title and a trailing `\label{…}` optional.
const ENV_OPEN = /^\s*\\begin\{([A-Za-z]+\*?)\}\s*(?:\[([^\]]*)\])?\s*(?:\\label\{[^}]*\})?\s*$/;

// Floats box like callouts, numbered per type as LaTeX does, starred or not
// (`figure*` only spans two columns). Their `[…]` is placement, not a title.
const FLOAT_ENVIRONMENTS = new Set(['figure', 'table']);

// beamer blocks take their title in a BRACE argument. Scoped to these three
// names ONLY, or `\begin{minipage}{0.45\textwidth}` becomes a callout. No
// nested braces in the title.
const BLOCK_OPEN =
  /^\s*\\begin\{(block|alertblock|exampleblock)\}\s*\{([^}]*)\}\s*(?:\\label\{[^}]*\})?\s*$/;

/** Whether a line is the `\end{<env>}` closing the given (raw, possibly starred) env. */
export function isTexEnvClose(lineText: string, env: string): boolean {
  const m = /^\s*\\end\{([A-Za-z]+\*?)\}\s*$/.exec(lineText);
  return m != null && m[1] === env;
}

/** Parse a lone `\begin{…}` line; null for envs that aren't callouts. */
export function parseTexEnvOpen(lineText: string): CalloutOpen | null {
  const block = BLOCK_OPEN.exec(lineText);
  if (block) {
    const type = block[1];
    return {
      type,
      label: LABELS[type],
      title: block[2],
      numbered: false,
      isClose: (t) => isTexEnvClose(t, type),
    };
  }

  const m = ENV_OPEN.exec(lineText);
  if (!m) return null;

  const rawEnv = m[1];
  const starred = rawEnv.endsWith('*');
  const type = (starred ? rawEnv.slice(0, -1) : rawEnv).toLowerCase();
  // `in`, not truthiness: the block family's label is deliberately empty.
  if (!(type in LABELS)) return null;
  const label = LABELS[type];
  const float = FLOAT_ENVIRONMENTS.has(type);

  const title = float ? null : (m[2] ?? null);
  // Only the same raw env closes it, so an inner `\end{proof}` doesn't.
  return {
    type,
    label,
    title,
    numbered: float || (!starred && !UNNUMBERED.has(type)),
    isClose: (t) => isTexEnvClose(t, rawEnv),
  };
}

/** Cached LaTeX callout scan. No verbatim guard on purpose: a callout typed
 *  inside verbatim is rare enough to accept. */
export const scanTexCallouts: ScanCallouts = makeCachedScanner(parseTexEnvOpen);

/** `lineCollapsed` comes from setup.ts (see LineCollapsed): it keeps the box
 *  bottom off list fences tex-list-plugin collapsed. */
export function texCalloutPlugin(lineCollapsed?: LineCollapsed, opts: CalloutOptions = {}): Extension {
  return makeCalloutField(scanTexCallouts, lineCollapsed, opts);
}

/** Up/Down stop on a collapsed `\end{…}` and reveal it (see makeFenceStopKeymap). */
export const texCalloutFenceKeymap: Extension = makeFenceStopKeymap(scanTexCallouts, isPreviewMode);
