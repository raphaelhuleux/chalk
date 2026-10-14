import { describe, it, expect, beforeEach } from 'vitest';
import { mdView, texView } from './helpers/views';

/**
 * A Quarto callout's id (`::: {#prf-pythagoras}`) is an anchor, and the label
 * widget that replaces the fence used to swallow it whole — the rendered block
 * said "Proof" and nothing said which proof, or that it could be referenced at
 * all.
 *
 * It now carries a dimmed pill beside the label, the same treatment the
 * heading id and `\label{…}` get. The LaTeX callouts share this widget and are
 * unaffected: `refId` is only ever set by the markdown ID-form open, so the
 * tex side passes nothing and renders nothing.
 */

const mount = (doc: string, caret = doc.length) =>
  mdView(doc, { ensureTree: true, cursor: caret });

const mountTex = (doc: string, caret = doc.length) =>
  texView(doc, { ensureTree: true, cursor: caret });

describe('a callout id is previewed beside its label', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('shows the id as a pill on an unnumbered block', () => {
    const view = mount('::: {#prf-pythagoras}\nbody\n:::\n\ntail');
    const label = view.dom.querySelector('.cm-callout-label');
    expect(label, 'the open fence renders a label widget').not.toBeNull();
    expect(label!.textContent).toContain('Proof');
    const pill = label!.querySelector('.cm-md-label-pill');
    expect(pill, 'the id must be shown, not swallowed').not.toBeNull();
    expect(pill!.textContent).toBe('prf-pythagoras');
    view.destroy();
  });

  it('shows the id alongside a number on a numbered block', () => {
    const view = mount('::: {#thm-pythagoras}\nbody\n:::\n\ntail');
    const label = view.dom.querySelector('.cm-callout-label');
    expect(label!.textContent).toContain('Theorem 1');
    expect(label!.querySelector('.cm-md-label-pill')!.textContent).toBe('thm-pythagoras');
    view.destroy();
  });

  it('shows no pill for a class-form callout, which has no id', () => {
    const view = mount('::: {.callout-note}\nbody\n:::\n\ntail');
    const label = view.dom.querySelector('.cm-callout-label');
    if (label) expect(label.querySelector('.cm-md-label-pill')).toBeNull();
    view.destroy();
  });

  it('leaves the LaTeX callouts alone — they carry no id', () => {
    const view = mountTex('\\begin{theorem}\nbody\n\\end{theorem}\n\ntail');
    const label = view.dom.querySelector('.cm-callout-label');
    expect(label, 'the tex open fence still renders its label').not.toBeNull();
    expect(label!.textContent).toContain('Theorem');
    expect(label!.querySelector('.cm-md-label-pill')).toBeNull();
    view.destroy();
  });
});
