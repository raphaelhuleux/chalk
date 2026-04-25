/**
 * CodeMirror 6 autocompletion source for LaTeX environments and commands.
 */

import {
  autocompletion,
  CompletionContext,
  CompletionResult,
  Completion,
} from '@codemirror/autocomplete';
import { Extension, Transaction } from '@codemirror/state';
import { EditorView } from '@codemirror/view';

// ── Environment names ───────────────────────────────────────────────

const ENVIRONMENTS = [
  // Document structure
  'document', 'abstract',
  // Sectioning-like
  'part', 'chapter',
  // Math
  'equation', 'equation*', 'align', 'align*', 'gather', 'gather*',
  'multline', 'multline*', 'alignat', 'alignat*', 'flalign', 'flalign*',
  'eqnarray', 'eqnarray*', 'split', 'cases', 'dcases',
  // Matrices
  'matrix', 'pmatrix', 'bmatrix', 'Bmatrix', 'vmatrix', 'Vmatrix',
  'smallmatrix',
  // Floats
  'figure', 'figure*', 'table', 'table*', 'subfigure',
  // Lists
  'itemize', 'enumerate', 'description',
  // Tables
  'tabular', 'tabular*', 'tabularx', 'longtable', 'array',
  // Text
  'center', 'flushleft', 'flushright', 'quote', 'quotation', 'verse',
  'verbatim', 'minipage', 'titlepage',
  // Theorem-like
  'theorem', 'lemma', 'proposition', 'corollary', 'definition',
  'example', 'remark', 'proof', 'assumption',
  // Beamer
  'frame', 'block', 'alertblock', 'exampleblock', 'columns', 'column',
  // TikZ
  'tikzpicture', 'scope', 'axis',
  // Misc
  'appendix', 'thebibliography', 'filecontents',
];

// ── Common commands ─────────────────────────────────────────────────

const COMMANDS: Completion[] = [
  // Fractions & math operators
  { label: '\\frac', detail: 'fraction', apply: '\\frac{$1}{$2}' },
  { label: '\\dfrac', detail: 'display fraction', apply: '\\dfrac{$1}{$2}' },
  { label: '\\tfrac', detail: 'text fraction', apply: '\\tfrac{$1}{$2}' },
  { label: '\\sqrt', detail: 'square root', apply: '\\sqrt{$1}' },
  { label: '\\sum', detail: 'summation' },
  { label: '\\prod', detail: 'product' },
  { label: '\\int', detail: 'integral' },
  { label: '\\iint', detail: 'double integral' },
  { label: '\\iiint', detail: 'triple integral' },
  { label: '\\oint', detail: 'contour integral' },
  { label: '\\lim', detail: 'limit' },
  { label: '\\inf', detail: 'infimum' },
  { label: '\\sup', detail: 'supremum' },
  { label: '\\max', detail: 'maximum' },
  { label: '\\min', detail: 'minimum' },
  { label: '\\log', detail: 'logarithm' },
  { label: '\\ln', detail: 'natural log' },
  { label: '\\exp', detail: 'exponential' },
  { label: '\\sin', detail: 'sine' },
  { label: '\\cos', detail: 'cosine' },
  { label: '\\tan', detail: 'tangent' },
  { label: '\\arcsin', detail: 'arc sine' },
  { label: '\\arccos', detail: 'arc cosine' },
  { label: '\\arctan', detail: 'arc tangent' },
  { label: '\\partial', detail: 'partial derivative symbol' },
  { label: '\\nabla', detail: 'nabla/gradient' },

  // Decorations
  { label: '\\hat', detail: 'hat accent', apply: '\\hat{$1}' },
  { label: '\\bar', detail: 'bar accent', apply: '\\bar{$1}' },
  { label: '\\tilde', detail: 'tilde accent', apply: '\\tilde{$1}' },
  { label: '\\vec', detail: 'vector arrow', apply: '\\vec{$1}' },
  { label: '\\dot', detail: 'dot accent', apply: '\\dot{$1}' },
  { label: '\\ddot', detail: 'double dot', apply: '\\ddot{$1}' },
  { label: '\\overline', detail: 'overline', apply: '\\overline{$1}' },
  { label: '\\underline', detail: 'underline', apply: '\\underline{$1}' },
  { label: '\\overbrace', detail: 'overbrace', apply: '\\overbrace{$1}' },
  { label: '\\underbrace', detail: 'underbrace', apply: '\\underbrace{$1}' },
  { label: '\\widehat', detail: 'wide hat', apply: '\\widehat{$1}' },
  { label: '\\widetilde', detail: 'wide tilde', apply: '\\widetilde{$1}' },

  // Font styles
  { label: '\\mathbf', detail: 'bold math', apply: '\\mathbf{$1}' },
  { label: '\\mathbb', detail: 'blackboard bold', apply: '\\mathbb{$1}' },
  { label: '\\mathcal', detail: 'calligraphic', apply: '\\mathcal{$1}' },
  { label: '\\mathfrak', detail: 'fraktur', apply: '\\mathfrak{$1}' },
  { label: '\\mathrm', detail: 'roman math', apply: '\\mathrm{$1}' },
  { label: '\\mathit', detail: 'italic math', apply: '\\mathit{$1}' },
  { label: '\\mathsf', detail: 'sans-serif math', apply: '\\mathsf{$1}' },
  { label: '\\mathtt', detail: 'typewriter math', apply: '\\mathtt{$1}' },
  { label: '\\boldsymbol', detail: 'bold symbol', apply: '\\boldsymbol{$1}' },
  { label: '\\textbf', detail: 'bold text', apply: '\\textbf{$1}' },
  { label: '\\textit', detail: 'italic text', apply: '\\textit{$1}' },
  { label: '\\texttt', detail: 'monospace text', apply: '\\texttt{$1}' },
  { label: '\\emph', detail: 'emphasis', apply: '\\emph{$1}' },
  { label: '\\text', detail: 'text in math', apply: '\\text{$1}' },

  // Greek letters
  { label: '\\alpha', detail: 'α' }, { label: '\\beta', detail: 'β' },
  { label: '\\gamma', detail: 'γ' }, { label: '\\Gamma', detail: 'Γ' },
  { label: '\\delta', detail: 'δ' }, { label: '\\Delta', detail: 'Δ' },
  { label: '\\epsilon', detail: 'ε' }, { label: '\\varepsilon', detail: 'ε' },
  { label: '\\zeta', detail: 'ζ' }, { label: '\\eta', detail: 'η' },
  { label: '\\theta', detail: 'θ' }, { label: '\\Theta', detail: 'Θ' },
  { label: '\\vartheta', detail: 'ϑ' },
  { label: '\\iota', detail: 'ι' }, { label: '\\kappa', detail: 'κ' },
  { label: '\\lambda', detail: 'λ' }, { label: '\\Lambda', detail: 'Λ' },
  { label: '\\mu', detail: 'μ' }, { label: '\\nu', detail: 'ν' },
  { label: '\\xi', detail: 'ξ' }, { label: '\\Xi', detail: 'Ξ' },
  { label: '\\pi', detail: 'π' }, { label: '\\Pi', detail: 'Π' },
  { label: '\\rho', detail: 'ρ' }, { label: '\\varrho', detail: 'ϱ' },
  { label: '\\sigma', detail: 'σ' }, { label: '\\Sigma', detail: 'Σ' },
  { label: '\\tau', detail: 'τ' },
  { label: '\\upsilon', detail: 'υ' }, { label: '\\Upsilon', detail: 'Υ' },
  { label: '\\phi', detail: 'φ' }, { label: '\\Phi', detail: 'Φ' },
  { label: '\\varphi', detail: 'φ' },
  { label: '\\chi', detail: 'χ' },
  { label: '\\psi', detail: 'ψ' }, { label: '\\Psi', detail: 'Ψ' },
  { label: '\\omega', detail: 'ω' }, { label: '\\Omega', detail: 'Ω' },

  // Relations & operators
  { label: '\\leq', detail: '≤' }, { label: '\\geq', detail: '≥' },
  { label: '\\neq', detail: '≠' }, { label: '\\approx', detail: '≈' },
  { label: '\\equiv', detail: '≡' }, { label: '\\sim', detail: '∼' },
  { label: '\\simeq', detail: '≃' }, { label: '\\propto', detail: '∝' },
  { label: '\\ll', detail: '≪' }, { label: '\\gg', detail: '≫' },
  { label: '\\subset', detail: '⊂' }, { label: '\\supset', detail: '⊃' },
  { label: '\\subseteq', detail: '⊆' }, { label: '\\supseteq', detail: '⊇' },
  { label: '\\in', detail: '∈' }, { label: '\\notin', detail: '∉' },
  { label: '\\cap', detail: '∩' }, { label: '\\cup', detail: '∪' },
  { label: '\\wedge', detail: '∧' }, { label: '\\vee', detail: '∨' },
  { label: '\\neg', detail: '¬' },
  { label: '\\forall', detail: '∀' }, { label: '\\exists', detail: '∃' },
  { label: '\\infty', detail: '∞' }, { label: '\\emptyset', detail: '∅' },
  { label: '\\times', detail: '×' }, { label: '\\cdot', detail: '·' },
  { label: '\\otimes', detail: '⊗' }, { label: '\\oplus', detail: '⊕' },

  // Arrows
  { label: '\\rightarrow', detail: '→' }, { label: '\\leftarrow', detail: '←' },
  { label: '\\Rightarrow', detail: '⇒' }, { label: '\\Leftarrow', detail: '⇐' },
  { label: '\\leftrightarrow', detail: '↔' },
  { label: '\\Leftrightarrow', detail: '⇔' },
  { label: '\\implies', detail: '⟹' }, { label: '\\iff', detail: '⟺' },
  { label: '\\to', detail: '→' }, { label: '\\mapsto', detail: '↦' },
  { label: '\\hookrightarrow', detail: '↪' },

  // Delimiters
  { label: '\\left', detail: 'left delimiter' },
  { label: '\\right', detail: 'right delimiter' },
  { label: '\\langle', detail: '⟨' }, { label: '\\rangle', detail: '⟩' },
  { label: '\\lceil', detail: '⌈' }, { label: '\\rceil', detail: '⌉' },
  { label: '\\lfloor', detail: '⌊' }, { label: '\\rfloor', detail: '⌋' },

  // Spacing
  { label: '\\quad', detail: 'quad space' },
  { label: '\\qquad', detail: 'double quad space' },
  { label: '\\hspace', detail: 'horizontal space', apply: '\\hspace{$1}' },
  { label: '\\vspace', detail: 'vertical space', apply: '\\vspace{$1}' },

  // Document commands
  { label: '\\section', detail: 'section', apply: '\\section{$1}' },
  { label: '\\subsection', detail: 'subsection', apply: '\\subsection{$1}' },
  { label: '\\subsubsection', detail: 'subsubsection', apply: '\\subsubsection{$1}' },
  { label: '\\paragraph', detail: 'paragraph', apply: '\\paragraph{$1}' },
  { label: '\\label', detail: 'label', apply: '\\label{$1}' },
  { label: '\\ref', detail: 'reference', apply: '\\ref{$1}' },
  { label: '\\eqref', detail: 'equation ref', apply: '\\eqref{$1}' },
  { label: '\\cite', detail: 'citation', apply: '\\cite{$1}' },
  { label: '\\footnote', detail: 'footnote', apply: '\\footnote{$1}' },
  { label: '\\includegraphics', detail: 'include image', apply: '\\includegraphics[width=$1]{$2}' },
  { label: '\\caption', detail: 'caption', apply: '\\caption{$1}' },
  { label: '\\input', detail: 'input file', apply: '\\input{$1}' },
  { label: '\\include', detail: 'include file', apply: '\\include{$1}' },
  { label: '\\usepackage', detail: 'use package', apply: '\\usepackage{$1}' },
  { label: '\\newcommand', detail: 'new command', apply: '\\newcommand{\\$1}{$2}' },
  { label: '\\renewcommand', detail: 'renew command', apply: '\\renewcommand{\\$1}{$2}' },
  { label: '\\item', detail: 'list item' },

  // Misc
  { label: '\\dots', detail: '…' }, { label: '\\cdots', detail: '⋯' },
  { label: '\\ldots', detail: '…' }, { label: '\\vdots', detail: '⋮' },
  { label: '\\ddots', detail: '⋱' },
  { label: '\\hbar', detail: 'ℏ' }, { label: '\\ell', detail: 'ℓ' },
  { label: '\\dagger', detail: '†' },
];

// ── Environment boilerplate ──────────────────────────────────────────

/** Returns the text to insert after the env name inside \begin{...
 *  `suffix` is either `}` or `` (if `}` already exists). */
const ENV_BOILERPLATE: Record<string, (suffix: string) => string> = {
  figure: (s) =>
    `figure${s}[htbp]\n    \\centering\n    \\includegraphics[width=0.8\\textwidth]{}\n    \\caption{}\n    \\label{fig:}\n\\end{figure}`,
  'figure*': (s) =>
    `figure*${s}[htbp]\n    \\centering\n    \\includegraphics[width=\\textwidth]{}\n    \\caption{}\n    \\label{fig:}\n\\end{figure*}`,
  table: (s) =>
    `table${s}[htbp]\n    \\centering\n    \\caption{}\n    \\label{tab:}\n    \\begin{tabular}{}\n        \\hline\n        \n        \\hline\n    \\end{tabular}\n\\end{table}`,
  'table*': (s) =>
    `table*${s}[htbp]\n    \\centering\n    \\caption{}\n    \\label{tab:}\n    \\begin{tabular}{}\n        \\hline\n        \n        \\hline\n    \\end{tabular}\n\\end{table*}`,
  equation: (s) =>
    `equation${s}\n    \n    \\label{eq:}\n\\end{equation}`,
  'equation*': (s) =>
    `equation*${s}\n    \n\\end{equation*}`,
  align: (s) =>
    `align${s}\n    \n\\end{align}`,
  'align*': (s) =>
    `align*${s}\n    \n\\end{align*}`,
  gather: (s) =>
    `gather${s}\n    \n\\end{gather}`,
  'gather*': (s) =>
    `gather*${s}\n    \n\\end{gather*}`,
  itemize: (s) =>
    `itemize${s}\n    \\item \n\\end{itemize}`,
  enumerate: (s) =>
    `enumerate${s}\n    \\item \n\\end{enumerate}`,
  description: (s) =>
    `description${s}\n    \\item[] \n\\end{description}`,
  minipage: (s) =>
    `minipage${s}{0.45\\textwidth}\n    \n\\end{minipage}`,
  frame: (s) =>
    `frame${s}{}\n    \n\\end{frame}`,
  cases: (s) =>
    `cases${s}\n     & \\\\\\\\\n     & \n\\end{cases}`,
  tikzpicture: (s) =>
    `tikzpicture${s}[]\n    \n\\end{tikzpicture}`,
};

// ── Completion source ───────────────────────────────────────────────

function latexCompletions(context: CompletionContext): CompletionResult | null {
  // Match \begin{ or \end{ followed by partial env name.
  const envMatch = context.matchBefore(/\\(?:begin|end)\{[a-zA-Z*]*/);
  if (envMatch) {
    const braceIdx = envMatch.text.indexOf('{');
    const prefix = envMatch.text.slice(braceIdx + 1);
    const from = envMatch.from + braceIdx + 1;

    // Check if there's already a closing } after the cursor — if so, consume it.
    const afterCursor = context.state.sliceDoc(context.pos, context.pos + 1);
    const hasClosingBrace = afterCursor === '}';
    const to = hasClosingBrace ? context.pos + 1 : context.pos;

    // Determine if we're in \begin or \end.
    const isBegin = envMatch.text.startsWith('\\begin');

    return {
      from,
      options: ENVIRONMENTS
        .filter(e => e.startsWith(prefix))
        .map(e => {
          if (!isBegin) {
            return { label: e, type: 'keyword', apply: e + suffix };
          }
          const boilerplate = ENV_BOILERPLATE[e];
          if (boilerplate) {
            return {
              label: e,
              type: 'keyword',
              apply: (view, completion, from2, to2) => {
                view.dispatch({
                  changes: { from: from2, to, insert: boilerplate('}') },
                });
              },
            };
          }
          // Generic: close the brace and add \end{env}
          return {
            label: e,
            type: 'keyword',
            apply: (view, completion, from2, to2) => {
              view.dispatch({
                changes: { from: from2, to, insert: e + '}\n    \n\\end{' + e + '}' },
              });
            },
          };
        }),
      validFor: /^[a-zA-Z*]*$/,
    };
  }

  // Match \ followed by partial command name (at least 1 char).
  const cmdMatch = context.matchBefore(/\\[a-zA-Z]+/);
  if (cmdMatch) {
    return {
      from: cmdMatch.from,
      options: COMMANDS.map(c => ({ ...c, type: 'function' })),
      validFor: /^\\[a-zA-Z]*$/,
    };
  }

  return null;
}

// ── Public extension ────────────────────────────────────────────────

export function latexCompletionExtension(): Extension {
  return autocompletion({
    override: [latexCompletions],
    activateOnTyping: true,
    defaultKeymap: true,
  });
}
