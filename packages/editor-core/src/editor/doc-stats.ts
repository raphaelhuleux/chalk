import type { EditorState, Text } from '@codemirror/state';
import type { Language } from './setup';
import { commentStart } from './tex-lines';
import { mathRegionsOf } from './tex-math-incremental';
import { docText } from '../utils/doc-text';

/** Word and character counts of a document's prose, for the outline panel. */
export interface DocumentStats {
  words: number;
  /** Prose characters, spaces excluded. */
  characters: number;
  /** Words inside a non-empty selection, else null. */
  selectionWords: number | null;
}

// A word: letters or digits, joined by an apostrophe, hyphen or point
// (`don't`, `well-known`, `3.5`), so punctuation and markup never count.
const WORD = /[\p{L}\p{N}]+(?:['’.\-][\p{L}\p{N}]+)*/gu;

// LaTeX commands whose arguments are not prose: references, files, layout and
// definitions. Their whole call (options and first brace group) is dropped.
const TEX_NON_PROSE =
  /\\(?:label|ref|eqref|[cC]ref|autoref|vref|pageref|cite[a-zA-Z]*|[pP]arencite|[tT]extcite|nocite|includegraphics|input|include|bibliography|bibliographystyle|usepackage|documentclass|begin|end|[vh]space|url|href|(?:re)?newcommand|providecommand|newenvironment|DeclareMathOperator|setlength|addtolength|setcounter|graphicspath)\*?(?:\[[^\]\n]*\])*(?:\{[^{}]*\})?/g;
// Any other command name (its brace arguments stay: `\emph{word}` counts).
const TEX_COMMAND = /\\(?:[A-Za-z@]+\*?|.)(?:\[[^\]\n]*\])?/g;

/** Blank `[from, to)` in a char array, keeping offsets aligned with the doc. */
function blank(chars: string[], from: number, to: number): void {
  for (let i = Math.max(0, from); i < Math.min(chars.length, to); i++) {
    if (chars[i] !== '\n') chars[i] = ' ';
  }
}

/** Blank every match of `re` in `text`, keeping its length and newlines. */
function blankMatches(text: string, re: RegExp): string {
  return text.replace(re, (m) => m.replace(/[^\n]/g, ' '));
}

/** The document with everything but LaTeX prose blanked, same length. */
function texProse(state: EditorState): string {
  const text = docText(state.doc);
  const chars = text.split(''); // UTF-16 units, like doc offsets
  // Only the body counts when the file has one.
  const begin = text.indexOf('\\begin{document}');
  if (begin !== -1) blank(chars, 0, begin + '\\begin{document}'.length);
  const end = text.indexOf('\\end{document}');
  if (end !== -1) blank(chars, end, text.length);
  let from = 0;
  for (const line of text.split('\n')) {
    const cs = commentStart(line);
    if (cs !== -1) blank(chars, from + cs, from + line.length);
    from += line.length + 1;
  }
  for (const r of mathRegionsOf(state)) blank(chars, r.from, r.to);
  // Masked text from here on, so a command inside a comment or formula
  // can't swallow prose after it.
  let masked = blankMatches(chars.join(''), TEX_NON_PROSE);
  masked = blankMatches(masked, TEX_COMMAND);
  // Grouping braces and `~` ties are markup, not characters.
  return blankMatches(masked, /[{}~]/g);
}

const MD_FRONTMATTER = /^---\n[\s\S]*?\n(?:---|\.\.\.)\s*(?:\n|$)/;
const MD_BLANKED = [
  /^(`{3,}|~{3,})[^\n]*\n[\s\S]*?(?:\n\1[^\n]*|$)/gm, // fenced code
  /`[^`\n]+`/g, // inline code
  /\$\$[\s\S]*?\$\$/g, // display math
  /(?<![\\$])\$(?!\s)[^$\n]+?(?<!\s|\\)\$/g, // inline math
  /<!--[\s\S]*?-->/g, // HTML comments
  /!\[[^\]]*\]\([^)]*\)/g, // images
  /\]\([^)]*\)/g, // a link's target (its text stays)
  /<https?:[^>\s]+>/g, // autolinks
  /\{[#.][^}\n]*\}/g, // Quarto attributes `{#sec-x}`, `{.proof}`
  /^:{3,}.*$/gm, // Quarto fence lines
  /\[?@[\w:.-]+\]?/g, // cross-references and citations
];

/** The document with everything but Markdown prose blanked, same length. */
function mdProse(state: EditorState): string {
  const text = docText(state.doc);
  const fm = MD_FRONTMATTER.exec(text);
  let masked = fm ? blankMatches(fm[0], /[^\n]/g) + text.slice(fm[0].length) : text;
  for (const re of MD_BLANKED) masked = blankMatches(masked, re);
  return masked;
}

// One prose pass per document: a caret move only recounts its selection.
const proseCache = new WeakMap<Text, { language: Language; prose: string; words: number; characters: number }>();

function proseOf(state: EditorState, language: Language) {
  const hit = proseCache.get(state.doc);
  if (hit && hit.language === language) return hit;
  const prose = language === 'tex' ? texProse(state) : mdProse(state);
  const entry = {
    language,
    prose,
    words: prose.match(WORD)?.length ?? 0,
    characters: prose.replace(/\s/g, '').length,
  };
  proseCache.set(state.doc, entry);
  return entry;
}

export function documentStats(state: EditorState, language: Language): DocumentStats {
  const { prose, words, characters } = proseOf(state, language);
  const sel = state.selection.main;
  const selectionWords = sel.empty ? null : (prose.slice(sel.from, sel.to).match(WORD)?.length ?? 0);
  return { words, characters, selectionWords };
}
