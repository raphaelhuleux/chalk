import { describe, it, expect } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { EditorState, Text } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { mathSyntax } from '../src/editor/md-math-plugin';
import { highlightSyntax } from '../src/editor/md-highlight-plugin';
import { scanMathRegions } from '../src/editor/tex-math';
import { KaTeXCache } from '../src/utils/katex-cache';
import { parseFenceOpen, isFenceClose } from '../src/editor/md-callout-plugin';
import { parseTexEnvOpen } from '../src/editor/tex-callout-plugin';
import { crossrefIndex } from '../src/editor/crossref-index';
import { extractOutline } from '../src/editor/outline';

// ---------------------------------------------------------------------------
//  The shipped Welcome.md / Welcome.tex are the first thing a new user sees,
//  and every line of them is a claim about this engine: this fence is a
//  theorem, this reference resolves, this equation renders. A claim that stops
//  being true is a worse bug here than anywhere else in the app — the user has
//  no way to tell "Chalk is broken" from "I mistyped", so they conclude the
//  former and stop.
//
//  So the samples are tested rather than proofread, against the SAME parsers
//  the editor runs. This reaches across into the Mac app target for the text (the
//  samples live in Swift, where the app seeds them) instead of keeping a copy
//  here, because a copy is a thing that drifts and this test exists to catch
//  drift. Reading a file is not a host dependency: the engine itself stays
//  host-agnostic, and the test skips cleanly when editor-core is checked out
//  without the app beside it.
// ---------------------------------------------------------------------------

const SWIFT = join(__dirname, '../../../mac/Chalk/Document/SampleContent.swift');

/** Pull a Swift raw literal (`#"""` … `"""#`) and undo the indentation Swift
 *  strips at runtime, so the string under test is the bytes that hit disk. */
function swiftRawLiteral(source: string, name: string): string {
  const open = new RegExp(`static let ${name} = #"""\\n`);
  const start = open.exec(source);
  if (!start) throw new Error(`no raw literal named ${name}`);
  const body = source.slice(start.index + start[0].length);
  const end = body.indexOf('"""#');
  if (end < 0) throw new Error(`unterminated raw literal ${name}`);
  // Swift strips the closing delimiter's indentation from every line.
  const closingIndent = /([ \t]*)"""#/.exec(body.slice(end - 40, end + 4))?.[1] ?? '';
  return body
    .slice(0, end)
    .split('\n')
    .map((line) => (line.startsWith(closingIndent) ? line.slice(closingIndent.length) : line))
    .join('\n')
    .replace(/\n[ \t]*$/, '\n');
}

const hasApp = existsSync(SWIFT);
const swift = hasApp ? readFileSync(SWIFT, 'utf8') : '';
const md = hasApp ? swiftRawLiteral(swift, 'welcomeMarkdown') : '';
const tex = hasApp ? swiftRawLiteral(swift, 'welcomeTeX') : '';

/** Every math region, rendered the way the widgets render it. `null` is how
 *  KaTeXCache reports a parse failure — in the app that is a blank box. */
function unrenderable(doc: string): string[] {
  const cache = new KaTeXCache();
  return mathRegions(doc)
    .map((r) => ({ src: doc.slice(r.from, r.to), display: r.display }))
    .filter(({ src, display }) => cache.render(stripDelimiters(src), display) === null)
    .map(({ src }) => src);
}

/** Named so the count can be asserted separately: "nothing failed to render"
 *  is also true of a document with no maths in it, and that is how this test
 *  would go quietly vacuous. */
function mathRegions(doc: string) {
  return scanMathRegions(doc);
}

/** KaTeX takes the body, not the `$$`/`\[`/`\(` wrapper (environments keep
 *  their own `\begin`/`\end`, which KaTeX parses). */
function stripDelimiters(src: string): string {
  if (src.startsWith('\\begin{')) return src;
  if (src.startsWith('$$')) return src.slice(2, -2);
  if (src.startsWith('\\[') || src.startsWith('\\(')) return src.slice(2, -2);
  return src.slice(1, -1);
}

/** Backticked spans are not maths: the Markdown parser tokenises `InlineCode`
 *  before `InlineMath`, so the lone `$` in a snippet trigger like `;$` never
 *  opens a region in the editor. The raw-text scanner has no tree, so blank
 *  the spans (keeping offsets) before handing it the document. */
function withoutCodeSpans(doc: string): string {
  return doc.replace(/`[^`\n]*`/g, (m) => ' '.repeat(m.length));
}

/** The markdown outline walks the syntax tree, so the state needs the language
 *  and a finished parse — the tex side is a line scan and needs neither.
 *
 *  The budget is generous and its result is checked: CM6 parses against a
 *  wall clock, and under vitest's parallel workers a slice can expire
 *  mid-document (see test/helpers/force-parse.ts). A partial tree yields an
 *  empty outline, which reads as "the sample has no headings" — a failure
 *  about the wrong thing, on a schedule that moves. */
function mdState(doc: string): EditorState {
  const seed = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [mathSyntax, highlightSyntax] })],
  });
  if (!ensureSyntaxTree(seed, seed.doc.length, 30_000))
    throw new Error('markdown parse did not finish inside the budget');
  // The empty transaction is required, not tidiness. CM6 holds the tree in two
  // places: `LanguageState.init` parses for a 20ms budget capped at the first
  // 3000 characters and stores whatever it reached in the state FIELD, while
  // `ensureSyntaxTree` advances the mutable parse CONTEXT and returns the
  // finished tree without ever writing it back. `extractOutline` reads
  // `syntaxTree()`, which is the field. A no-op update is what rebuilds the
  // field from the completed context.
  //
  // Skip it and this file passes on its own and fails inside the full suite,
  // where the workers compete for CPU and 20ms of wall clock buys less
  // parsing: the outline then sees 3 of Welcome.md's 7 headings.
  const state = seed.update({}).state;
  if (syntaxTree(state).length < state.doc.length)
    throw new Error('syntaxTree() is still partial after the parse');
  return state;
}

describe.skipIf(!hasApp)('the seeded Welcome samples', () => {
  it('ships both documents', () => {
    expect(md).toMatch(/^# Welcome to Chalk/);
    expect(tex).toContain('\\documentclass{article}');
  });

  describe('Welcome.md', () => {
    it('renders every equation it shows', () => {
      expect(mathRegions(withoutCodeSpans(md)).length).toBe(6);
      expect(unrenderable(withoutCodeSpans(md))).toEqual([]);
    });

    it('opens a numbered theorem the reader can see numbered', () => {
      const open = md.split('\n').map(parseFenceOpen).filter(Boolean);
      expect(open.map((o) => [o!.type, o!.title, o!.numbered])).toEqual([
        ['theorem', 'Pythagoras', true],
        ['note', null, false],
      ]);
    });

    it('closes every fence it opens', () => {
      const opens = md.split('\n').filter((l) => parseFenceOpen(l) !== null).length;
      const closes = md.split('\n').filter(isFenceClose).length;
      expect(closes).toBe(opens);
    });

    it('resolves the cross-reference it promises resolves', () => {
      const entry = crossrefIndex(Text.of(md.split('\n'))).get('thm-pythagoras');
      expect(entry).toBeDefined();
      expect(`${entry!.label} ${entry!.number}`).toBe('Theorem 1');
    });

    it('gives the outline something to list', () => {
      const outline = extractOutline(mdState(md), 'md');
      expect(outline.filter((i) => i.kind === 'heading').length).toBeGreaterThan(4);
      expect(outline.some((i) => i.kind === 'callout' && i.title === 'Pythagoras')).toBe(true);
    });
  });

  describe('Welcome.tex', () => {
    it('renders every equation it shows', () => {
      expect(mathRegions(tex).length).toBe(11);
      expect(unrenderable(tex)).toEqual([]);
    });

    it('draws the three environments it says it draws', () => {
      const open = tex.split('\n').map(parseTexEnvOpen).filter(Boolean);
      expect(open.map((o) => [o!.type, o!.title])).toEqual([
        ['definition', 'Orthogonality'],
        ['theorem', 'Pythagoras'],
        ['proof', null],
      ]);
    });

    it('gives the outline its sections', () => {
      const outline = extractOutline(EditorState.create({ doc: tex }), 'tex');
      expect(outline.filter((i) => i.kind === 'heading').map((i) => i.title)).toEqual([
        'Maths where you wrote it',
        'Theorems',
        'What stays as source',
        'Snippets',
        'Getting around',
      ]);
    });
  });
});
