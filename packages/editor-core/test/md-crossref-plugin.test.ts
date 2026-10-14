import { describe, it, expect, beforeEach } from 'vitest';
import { mdView } from './helpers/views';

const mountMd = (doc: string, caret = doc.length) =>
  mdView(doc, { ensureTree: true, cursor: caret });

const contentText = (view: { dom: HTMLElement }) =>
  view.dom.querySelector('.cm-content')!.textContent ?? '';

describe('md cross-reference resolution', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  /**
   * A resolved reference renders its KEY in a pill, the way tex renders
   * `\ref{…}` (R-T4) — not a resolved "Prefix Number" (owner request
   * 2026-08-26). The number is the one thing you cannot act on from the
   * reference, and for the unnumbered kinds resolving produced a bare "Proof"
   * that named no particular one. The numbering itself still exists and is
   * still tested, in crossref-index.test.ts.
   */
  it('renders a resolved @eq-ols as its key, in a pill', () => {
    const view = mountMd('See @eq-ols here.\n\n$$\nx\n$$ {#eq-ols}');
    const spans = [...view.dom.querySelectorAll('.cm-crossref')].map((e) => e.textContent);
    expect(spans).toContain('eq-ols');
    expect(view.dom.querySelector('.cm-md-ref-pill')).not.toBeNull();
    expect(contentText(view)).not.toContain('@eq-ols'); // the `@` is replaced
    view.destroy();
  });

  it('renders the suppressed form (-@eq-ols) as the key too', () => {
    // `-@` suppresses the PREFIX in Quarto's output. With the key shown there
    // is no prefix to suppress, so both forms read the same here; the source
    // still says which it is, and reveals on caret.
    const view = mountMd('residual (-@eq-ols) zero.\n\n$$\nx\n$$ {#eq-ols}');
    const spans = [...view.dom.querySelectorAll('.cm-crossref')].map((e) => e.textContent);
    expect(spans).toContain('eq-ols');
    view.destroy();
  });

  it('renders a section ref as its key', () => {
    const view = mountMd('# A {#sec-a}\n\n## B {#sec-b}\n\nSee @sec-b.');
    const spans = [...view.dom.querySelectorAll('.cm-crossref')].map((e) => e.textContent);
    expect(spans).toContain('sec-b');
    view.destroy();
  });

  it('renders an unnumbered kind as its key, not a bare prefix', () => {
    // The case that prompted the change: `prf-` carries no number, so the old
    // rendering was the word "Proof" — true of every proof in the document.
    const view = mountMd('::: {#prf-pythagoras}\nbody\n:::\n\nSee @prf-pythagoras.');
    const spans = [...view.dom.querySelectorAll('.cm-crossref')].map((e) => e.textContent);
    expect(spans).toContain('prf-pythagoras');
    expect(spans).not.toContain('Proof');
    view.destroy();
  });

  it('leaves a reference inside code or math as source', () => {
    const view = mountMd(
      [
        '# A {#sec-a}',
        '',
        'Inline `see @sec-a` code.',
        '',
        '```',
        '@sec-a',
        '```',
        '',
        '```python',
        'x = "@sec-a"',
        '```',
        '',
        '    indented @sec-a',
        '',
        'Real @sec-a.',
      ].join('\n'),
      0,
    );
    expect(view.dom.querySelectorAll('.cm-crossref')).toHaveLength(1);
    expect(view.dom.querySelectorAll('.cm-crossref-unresolved')).toHaveLength(0);
    view.destroy();
  });

  it('marks an unknown key as unresolved and keeps the raw text', () => {
    const view = mountMd('See @thm-doesnotexist please.');
    const un = view.dom.querySelector('.cm-crossref-unresolved');
    expect(un).not.toBeNull();
    expect(un!.textContent).toBe('@thm-doesnotexist');
    expect(view.dom.querySelector('.cm-crossref')).toBeNull(); // nothing resolved
    view.destroy();
  });

  it('leaves an escaped \\@ email alone', () => {
    const view = mountMd('write to contact\\@example.com now');
    expect(view.dom.querySelector('.cm-crossref')).toBeNull();
    expect(view.dom.querySelector('.cm-crossref-unresolved')).toBeNull();
    view.destroy();
  });

  it('does not treat an @ inside math as a reference', () => {
    // `$a @ b$` — the @ is inside inline math; no known prefix follows it either.
    const view = mountMd('inline $a @ b$ math');
    expect(view.dom.querySelector('.cm-crossref')).toBeNull();
    expect(view.dom.querySelector('.cm-crossref-unresolved')).toBeNull();
    view.destroy();
  });

  it('reveals the raw @label when the caret is on it', () => {
    const doc = 'See @thm-x.\n\n::: {#thm-x}\nbody\n:::';
    const view = mountMd(doc, 6); // caret inside "@thm-x"
    expect(contentText(view)).toContain('@thm-x');
    view.destroy();
  });

  /**
   * A reference is one token, and both of its edges are places you edit from:
   * the left to retype the `@`, the right to fix the tail of the key. The
   * window used to exclude its end, so `@thm-x|` rendered the pill and the
   * last character could not be reached with the source showing — the same
   * defect the heading id had. The tex pills have always included it (R-T4's
   * `[cmdFrom, to+1)`).
   */
  it('reveals with the caret immediately BEFORE the @', () => {
    const doc = 'See @thm-x.\n\n::: {#thm-x}\nbody\n:::';
    const view = mountMd(doc, doc.indexOf('@')); // caret at the `@`
    expect(contentText(view)).toContain('@thm-x');
    view.destroy();
  });

  it('reveals with the caret immediately AFTER the key', () => {
    const doc = 'See @thm-x.\n\n::: {#thm-x}\nbody\n:::';
    const view = mountMd(doc, doc.indexOf('@') + '@thm-x'.length);
    expect(contentText(view)).toContain('@thm-x');
    view.destroy();
  });

  it('still renders the reference from elsewhere on the line', () => {
    const doc = 'See @thm-x.\n\n::: {#thm-x}\nbody\n:::';
    const view = mountMd(doc, 0);
    expect(contentText(view)).not.toContain('@thm-x');
    view.destroy();
  });
});
