/** LaTeX autocompletion: environments, text-mode commands, arguments. */

import {
  autocompletion,
  CompletionContext,
  CompletionResult,
  Completion,
} from '@codemirror/autocomplete';
import { EditorState, Extension, Text } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { isInMathContextTex } from './tex-math';
import { emptyArgumentCompletion, emptySlotAt } from './completion-trigger';
import { insertSnippetBody } from './hsnips-plugin';
import {
  listFiles,
  workspaceAccessFacet,
  workspaceCitations,
  type WorkspaceFileKind,
} from './workspace-files';
import { inLineComment } from './tex-lines';
import { docText } from '../utils/doc-text';
import { memoByDoc } from '../utils/memo-by-doc';

// ── Environment names ───────────────────────────────────────────────

// Grouped so each row can show its kind ("cases is math, description is a
// list"), which the name alone doesn't tell you.
const ENVIRONMENT_GROUPS: Record<string, string[]> = {
  document: ['document', 'abstract', 'part', 'chapter', 'appendix', 'thebibliography', 'filecontents'],
  math: [
    'equation', 'equation*', 'align', 'align*', 'gather', 'gather*',
    'multline', 'multline*', 'alignat', 'alignat*', 'flalign', 'flalign*',
    'eqnarray', 'eqnarray*', 'split', 'cases', 'dcases',
  ],
  matrix: ['matrix', 'pmatrix', 'bmatrix', 'Bmatrix', 'vmatrix', 'Vmatrix', 'smallmatrix'],
  float: ['figure', 'figure*', 'table', 'table*', 'subfigure'],
  list: ['itemize', 'enumerate', 'description'],
  tabular: ['tabular', 'tabular*', 'tabularx', 'longtable', 'array'],
  text: [
    'center', 'flushleft', 'flushright', 'quote', 'quotation', 'verse',
    'verbatim', 'minipage', 'titlepage',
  ],
  theorem: [
    'theorem', 'lemma', 'proposition', 'corollary', 'definition',
    'example', 'remark', 'proof', 'assumption',
  ],
  beamer: ['frame', 'block', 'alertblock', 'exampleblock', 'columns', 'column'],
  tikz: ['tikzpicture', 'scope', 'axis'],
};

const ENVIRONMENTS: Array<{ name: string; group: string }> = Object.entries(
  ENVIRONMENT_GROUPS,
).flatMap(([group, names]) => names.map((name) => ({ name, group })));

// ── Text-mode commands ──────────────────────────────────────────────
//
// Deliberately NOT a symbol list: the popup never fires inside math, so math
// symbols would only be offered where they are invalid. hsnips owns math.
//
// `body` is an hsnips snippet body (`$1`/`$0` are tab stops, see
// `insertSnippetBody`): a LaTeX `\\` needs four backslashes in the string
// value, eight in this source, as in assets/latex.hsnips.

interface CommandSpec {
  label: string;
  detail: string;
  /** hsnips snippet body; the label alone is inserted when absent. */
  body?: string;
  boost?: number;
}

const COMMANDS: CommandSpec[] = [
  // Structure
  { label: '\\begin', detail: 'environment', body: '\\begin{$1}\n    $0\n\\end{$1}', boost: 3 },
  { label: '\\end', detail: 'environment', body: '\\end{$1}' },
  { label: '\\documentclass', detail: 'preamble', body: '\\documentclass{$1}' },
  { label: '\\usepackage', detail: 'preamble', body: '\\usepackage{$1}' },
  { label: '\\part', detail: 'heading', body: '\\part{$1}' },
  { label: '\\chapter', detail: 'heading', body: '\\chapter{$1}' },
  { label: '\\section', detail: 'heading', body: '\\section{$1}', boost: 2 },
  { label: '\\subsection', detail: 'heading', body: '\\subsection{$1}', boost: 2 },
  { label: '\\subsubsection', detail: 'heading', body: '\\subsubsection{$1}' },
  { label: '\\paragraph', detail: 'heading', body: '\\paragraph{$1}' },
  { label: '\\appendix', detail: 'layout' },
  { label: '\\maketitle', detail: 'layout' },
  { label: '\\tableofcontents', detail: 'layout' },
  { label: '\\newpage', detail: 'layout' },
  { label: '\\clearpage', detail: 'layout' },

  // Metadata
  { label: '\\title', detail: 'metadata', body: '\\title{$1}' },
  { label: '\\author', detail: 'metadata', body: '\\author{$1}' },
  { label: '\\date', detail: 'metadata', body: '\\date{$1}' },

  // References
  { label: '\\label', detail: 'reference', body: '\\label{$1}', boost: 1 },
  { label: '\\ref', detail: 'reference', body: '\\ref{$1}', boost: 2 },
  { label: '\\eqref', detail: 'reference', body: '\\eqref{$1}' },
  { label: '\\cite', detail: 'reference', body: '\\cite{$1}', boost: 1 },
  { label: '\\footnote', detail: 'reference', body: '\\footnote{$1}' },
  { label: '\\url', detail: 'reference', body: '\\url{$1}' },
  { label: '\\href', detail: 'reference', body: '\\href{$1}{$2}' },
  { label: '\\bibliography', detail: 'reference', body: '\\bibliography{$1}' },
  { label: '\\bibliographystyle', detail: 'reference', body: '\\bibliographystyle{$1}' },

  // Content
  { label: '\\includegraphics', detail: 'content', body: '\\includegraphics[width=$1]{$2}$0' },
  { label: '\\graphicspath', detail: 'preamble', body: '\\graphicspath{{$1}}' },
  { label: '\\caption', detail: 'content', body: '\\caption{$1}' },
  { label: '\\centering', detail: 'layout' },
  { label: '\\item', detail: 'content', boost: 2 },
  { label: '\\input', detail: 'content', body: '\\input{$1}' },
  { label: '\\include', detail: 'content', body: '\\include{$1}' },

  // Text markup
  { label: '\\textbf', detail: 'text style', body: '\\textbf{$1}' },
  { label: '\\textit', detail: 'text style', body: '\\textit{$1}' },
  { label: '\\texttt', detail: 'text style', body: '\\texttt{$1}' },
  { label: '\\emph', detail: 'text style', body: '\\emph{$1}' },
  { label: '\\underline', detail: 'text style', body: '\\underline{$1}' },

  // Definitions
  { label: '\\newcommand', detail: 'definition', body: '\\newcommand{\\\\$1}{$2}' },
  { label: '\\renewcommand', detail: 'definition', body: '\\renewcommand{\\\\$1}{$2}' },
  { label: '\\newtheorem', detail: 'definition', body: '\\newtheorem{$1}{$2}' },
];

// ── Environment bodies ──────────────────────────────────────────────

/**
 * hsnips bodies for environments worth more than bare scaffolding. Each
 * starts with the env name and its closing `}`; `envApply` swallows a brace
 * already there. Same escaping as COMMANDS: a LaTeX row break is eight
 * backslashes in this source.
 */
const ENV_BODY: Record<string, string> = {
  figure:
    'figure}[htbp]\n    \\centering\n    \\includegraphics[width=0.8\\textwidth]{$1}\n    \\caption{$2}\n    \\label{fig:$3}\n\\end{figure}$0',
  'figure*':
    'figure*}[htbp]\n    \\centering\n    \\includegraphics[width=\\textwidth]{$1}\n    \\caption{$2}\n    \\label{fig:$3}\n\\end{figure*}$0',
  table:
    'table}[htbp]\n    \\centering\n    \\caption{$1}\n    \\label{tab:$2}\n    \\begin{tabular}{$3}\n        \\hline\n        $0\n        \\hline\n    \\end{tabular}\n\\end{table}',
  'table*':
    'table*}[htbp]\n    \\centering\n    \\caption{$1}\n    \\label{tab:$2}\n    \\begin{tabular}{$3}\n        \\hline\n        $0\n        \\hline\n    \\end{tabular}\n\\end{table*}',
  equation: 'equation}\n    $0\n    \\label{eq:$1}\n\\end{equation}',
  'equation*': 'equation*}\n    $0\n\\end{equation*}',
  align: 'align}\n    $0\n\\end{align}',
  'align*': 'align*}\n    $0\n\\end{align*}',
  gather: 'gather}\n    $0\n\\end{gather}',
  'gather*': 'gather*}\n    $0\n\\end{gather*}',
  itemize: 'itemize}\n    \\item $0\n\\end{itemize}',
  enumerate: 'enumerate}\n    \\item $0\n\\end{enumerate}',
  description: 'description}\n    \\item[$1] $0\n\\end{description}',
  minipage: 'minipage}{${1:0.45\\textwidth}}\n    $0\n\\end{minipage}',
  frame: 'frame}{$1}\n    $0\n\\end{frame}',
  cases: 'cases}\n     $1 & \\\\\\\\\n     $0 & \n\\end{cases}',
  tikzpicture: 'tikzpicture}[$1]\n    $0\n\\end{tikzpicture}',
};

function genericEnvBody(env: string): string {
  return env + '}\n    $0\n\\end{' + env + '}';
}

// ── Document symbols (labels + bibliography keys) ───────────────────
//
// One scan per document (memoByDoc), so `\ref{` completion doesn't rescan on
// every keystroke.

interface TexSymbols {
  labels: string[];
  citations: string[];
}

const LABEL_DEF = /\\label\{([^}\n]*)\}/g;
const BIBITEM_DEF = /\\bibitem(?:\[[^\]\n]*\])?\{([^}\n]*)\}/g;

const texSymbols = memoByDoc((doc: Text): TexSymbols => {
  const text = docText(doc);
  const collect = (re: RegExp): string[] => {
    const out = new Set<string>();
    re.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(text)) !== null) if (m[1]) out.add(m[1]);
    return [...out];
  };
  return { labels: collect(LABEL_DEF), citations: collect(BIBITEM_DEF) };
});

/** `\label{` offers namespace prefixes, not existing labels (those are
 *  for `\ref{`). */
const LABEL_PREFIXES = ['fig:', 'eq:', 'tab:', 'sec:', 'lst:', 'alg:'];

// ── Argument triggers ───────────────────────────────────────────────
//
// Shared by the completion source (partly typed argument) and
// `emptyArgumentCompletion` (an EMPTY one the caret moved into).

const FILE_COMMANDS = 'includegraphics|input|include';
const REF_COMMANDS = 'ref|eqref|autoref|pageref|cref|Cref|cite[a-zA-Z]*|label';

const FILE_ARGUMENT = new RegExp(`\\\\(${FILE_COMMANDS})(?:\\[[^\\]\\n]*\\])?\\{[^}\\n]*`);
const REF_ARGUMENT = new RegExp(`\\\\(?:${REF_COMMANDS})\\*?\\{[^}\\n]*`);

const EMPTY_ARGUMENT_OPEN = new RegExp(
  `\\\\(?:${FILE_COMMANDS}|${REF_COMMANDS}|begin|end)\\*?(?:\\[[^\\]\\n]*\\])?\\{$`,
);

function isEmptyTexArgument(state: EditorState, pos: number): boolean {
  return emptySlotAt(state, pos, EMPTY_ARGUMENT_OPEN, '}');
}

// ── Completion source ───────────────────────────────────────────────

/** Swallows an auto-closed `}` after `to`. Uses the apply-time `to`, never
 *  a captured `context.pos`: CM6 can apply many keystrokes after the source
 *  ran, and a stale position deletes the wrong range. */
function envApply(body: string) {
  return (view: EditorView, _completion: Completion, from: number, to: number): void => {
    const end = view.state.sliceDoc(to, to + 1) === '}' ? to + 1 : to;
    insertSnippetBody(view, from, end, body);
  };
}

function commandOption(spec: CommandSpec): Completion {
  return {
    label: spec.label,
    detail: spec.detail,
    type: 'function',
    boost: spec.boost,
    apply: spec.body
      ? (view: EditorView, _completion: Completion, from: number, to: number) =>
          void insertSnippetBody(view, from, to, spec.body as string)
      : undefined,
  };
}

// Static option lists, built once rather than per completion query.
const COMMAND_OPTIONS: readonly Completion[] = COMMANDS.map(commandOption);

function envOptions(isBegin: boolean): readonly Completion[] {
  return ENVIRONMENTS.map(({ name, group }) => ({
    label: name,
    // No detail when the env names its own group (`matrix`, `theorem`).
    detail: group === name ? undefined : group,
    type: 'keyword',
    apply: envApply(isBegin ? (ENV_BODY[name] ?? genericEnvBody(name)) : name + '}'),
  }));
}
const BEGIN_ENV_OPTIONS = envOptions(true);
const END_ENV_OPTIONS = envOptions(false);

function inComment(state: EditorState, pos: number): boolean {
  return inLineComment(state.doc.lineAt(pos), pos);
}

export function latexCompletionSource(
  context: CompletionContext,
): CompletionResult | Promise<CompletionResult | null> | null {
  if (inComment(context.state, context.pos)) return null;

  // Fires in math too: `\begin{` is an explicit request, and `pmatrix`/`cases`
  // live there.
  const envMatch = context.matchBefore(/\\(?:begin|end)\{[a-zA-Z*]*/);
  if (envMatch) {
    const braceIdx = envMatch.text.indexOf('{');
    const from = envMatch.from + braceIdx + 1;
    const isBegin = envMatch.text.startsWith('\\begin');

    return {
      from,
      // No prefix filter: CM6 fuzzy-ranks, so `mat` still reaches `pmatrix`.
      options: isBegin ? BEGIN_ENV_OPTIONS : END_ENV_OPTIONS,
      validFor: /^[a-zA-Z*]*$/,
    };
  }

  // File arguments complete from the host's file walk.
  const fileMatch = context.matchBefore(FILE_ARGUMENT);
  if (fileMatch) {
    const command = /^\\(\w+)/.exec(fileMatch.text)![1];
    const kinds: WorkspaceFileKind[] = command === 'includegraphics' ? ['image'] : ['document'];
    const from = fileMatch.from + fileMatch.text.indexOf('{') + 1;
    return listFiles(context.state.facet(workspaceAccessFacet), kinds).then((paths) => ({
      from,
      options: paths.map((path) => ({ label: path, type: 'file' })),
      validFor: /^[^}\n]*$/,
    }));
  }

  const refMatch = context.matchBefore(REF_ARGUMENT);
  if (refMatch) {
    const braceIdx = refMatch.text.indexOf('{');
    const command = refMatch.text.slice(1, braceIdx).replace('*', '');
    const symbols = texSymbols(context.state.doc);
    const from = refMatch.from + braceIdx + 1;
    const validFor = /^[^}\n]*$/;

    // Citations: local `\bibitem`s plus every `.bib` the host lists.
    if (command.startsWith('cite')) {
      const local = symbols.citations.map((c) => ({
        label: c,
        type: 'variable',
        detail: 'bibitem',
      }));
      return workspaceCitations(context.state.facet(workspaceAccessFacet)).then((external) => ({
        from,
        options: [
          ...local,
          ...external.map(({ key, file }) => ({ label: key, type: 'variable', detail: file })),
        ],
        validFor,
      }));
    }

    const options =
      command === 'label'
        ? LABEL_PREFIXES.map((p) => ({ label: p, type: 'namespace', detail: 'label prefix' }))
        : symbols.labels.map((l) => ({ label: l, type: 'variable', detail: 'label' }));
    return { from, options, validFor };
  }

  // A bare `\` opens the text-mode command list, never inside math (hsnips
  // owns math).
  const cmdMatch = context.matchBefore(/\\[a-zA-Z]*/);
  if (cmdMatch && !isInMathContextTex(context.state, context.pos)) {
    return {
      from: cmdMatch.from,
      // Full list: a `startsWith` pre-filter would defeat CM6's fuzzy ranking.
      options: COMMAND_OPTIONS,
      validFor: /^\\[a-zA-Z]*$/,
    };
  }

  return null;
}

// ── Public extension ────────────────────────────────────────────────

export function latexCompletionExtension(): Extension {
  return [
    autocompletion({
      override: [latexCompletionSource],
      activateOnTyping: true,
      defaultKeymap: true,
    }),
    emptyArgumentCompletion(isEmptyTexArgument),
  ];
}
