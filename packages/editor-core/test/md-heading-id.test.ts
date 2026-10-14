import { describe, it, expect } from 'vitest';
import { EditorSelection, EditorState } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { markdown } from '@codemirror/lang-markdown';
import { Table, TaskList, Strikethrough } from '@lezer/markdown';
import { mathSyntax } from '../src/editor/md-math-plugin';
import { highlightSyntax } from '../src/editor/md-highlight-plugin';
import { frontmatterSyntax } from '../src/editor/md-frontmatter';
import { buildLivePreviewDecorations } from '../src/editor/md-live-preview';

/**
 * A Quarto heading id (`# Setup {#sec-setup}`) is an anchor other text points
 * at with `@sec-setup`, so it has to stay READABLE without being edited — the
 * same treatment `\label{…}` gets on the tex side, where it renders as a
 * dimmed pill rather than vanishing.
 *
 * It used to be hidden outright, which made the anchor invisible: you could
 * not tell a heading carried an id, or which one, without putting the caret in
 * the line.
 */

function viewFor(doc: string, head: number): EditorView {
  const state = EditorState.create({
    doc,
    selection: EditorSelection.cursor(head),
    extensions: [
      markdown({
        extensions: [frontmatterSyntax, mathSyntax, highlightSyntax, Strikethrough, TaskList, Table],
      }),
    ],
  });
  const view = new EditorView({ state });
  // jsdom lays nothing out, so visibleRanges would be empty; the builder reads
  // them, so hand it the whole document the way the other preview tests do.
  Object.defineProperty(view, 'visibleRanges', {
    get: () => [{ from: 0, to: state.doc.length }],
  });
  return view;
}

/** The decorations covering `{#…}`, described as (from, to, kind). */
function attrDecorations(doc: string, head: number) {
  const view = viewFor(doc, head);
  const set = buildLivePreviewDecorations(view);
  const attrFrom = doc.indexOf(' {#');
  const attrTo = doc.indexOf('}', attrFrom) + 1;
  const found: Array<{ from: number; to: number; widget: unknown; hasWidget: boolean }> = [];
  set.between(attrFrom, attrTo, (from, to, value) => {
    const spec = (value as unknown as { spec?: Record<string, unknown> }).spec ?? {};
    found.push({ from, to, widget: spec.widget, hasWidget: spec.widget !== undefined });
  });
  view.destroy();
  return { found, attrFrom, attrTo };
}

describe('a heading id is previewed, not hidden', () => {
  const doc = '# Theorem-like blocks {#sec-theorems}\n\nbody\n';

  it('replaces the attribute with a widget rather than deleting it', () => {
    const { found, attrFrom, attrTo } = attrDecorations(doc, doc.indexOf('body'));
    const covering = found.filter((d) => d.from <= attrFrom + 1 && d.to >= attrTo);
    expect(covering.length, 'the attribute must be decorated when not being edited').toBeGreaterThan(0);
    expect(
      covering.some((d) => d.hasWidget),
      'it must carry a widget (the pill), not an empty replace that hides it',
    ).toBe(true);
  });

  it('renders the id as its text', () => {
    const { found } = attrDecorations(doc, doc.indexOf('body'));
    const widget = found.map((d) => d.widget).find(Boolean) as
      | { toDOM(): HTMLElement }
      | undefined;
    expect(widget, 'a pill widget must be emitted').toBeTruthy();
    expect(widget!.toDOM().textContent).toContain('sec-theorems');
  });
});

describe('a heading id reveals for editing', () => {
  const doc = '# Theorem-like blocks {#sec-theorems}\n\nbody\n';
  const closingBrace = doc.indexOf('}');
  const endOfHeading = closingBrace + 1; // the caret position AFTER `}`

  it('reveals with the caret inside the braces', () => {
    const { found } = attrDecorations(doc, closingBrace);
    expect(found.filter((d) => d.hasWidget)).toHaveLength(0);
  });

  it('reveals with the caret just AFTER the closing brace', () => {
    // The reported bug: `{#sec-theorems}|` showed the pill, so the last
    // character could never be edited from the right-hand side. The heading
    // ends at the line end, so this position is the only one past the
    // attribute — treating it as "outside" makes the id half-editable.
    const { found } = attrDecorations(doc, endOfHeading);
    expect(found.filter((d) => d.hasWidget)).toHaveLength(0);
  });

  it('still previews from another line', () => {
    const { found } = attrDecorations(doc, doc.indexOf('body'));
    expect(found.filter((d) => d.hasWidget).length).toBeGreaterThan(0);
  });

  it('does not reveal from the start of the NEXT line', () => {
    // One past the heading's end is the blank line; the reveal window must
    // stop at the line end, not spill into the following line.
    const nextLine = doc.indexOf('\n') + 1;
    const { found } = attrDecorations(doc, nextLine);
    expect(found.filter((d) => d.hasWidget).length).toBeGreaterThan(0);
  });
});
