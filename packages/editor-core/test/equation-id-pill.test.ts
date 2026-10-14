import { describe, it, expect, beforeEach } from 'vitest';
import { mdView } from './helpers/views';

/**
 * A labelled display equation (`$$ … $$ {#eq-ols}`) shows its number on the
 * right. The id itself was hidden with the rest of the attribute, so the block
 * said "(1)" and nothing said what `@eq-ols` was pointing at.
 *
 * It now carries the same dimmed pill the heading id and the callout id do,
 * on the LEFT — the number owns the right edge.
 */

const mount = (doc: string, caret = doc.length) =>
  mdView(doc, { ensureTree: true, cursor: caret });

describe('a labelled equation shows its id', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('renders the id as a pill beside the number', () => {
    const view = mount('$$\nx = 1\n$$ {#eq-ols}\n\ntail');
    const block = view.dom.querySelector('.cm-math-display');
    expect(block, 'the block renders').not.toBeNull();
    expect(block!.querySelector('.cm-eq-number')!.textContent).toBe('(1)');
    const pill = block!.querySelector('.cm-eq-id');
    expect(pill, 'the id must be visible, not swallowed with the attribute').not.toBeNull();
    expect(pill!.textContent).toBe('eq-ols');
    view.destroy();
  });

  it('renders no pill for an unlabelled equation', () => {
    const view = mount('$$\nx = 1\n$$\n\ntail');
    const block = view.dom.querySelector('.cm-math-display');
    expect(block!.querySelector('.cm-eq-id')).toBeNull();
    expect(block!.querySelector('.cm-eq-number')).toBeNull();
    view.destroy();
  });

  it('still reveals the whole attribute when the caret enters the block', () => {
    const doc = '$$\nx = 1\n$$ {#eq-ols}\n\ntail';
    const view = mount(doc, doc.indexOf('x = 1'));
    expect(view.dom.querySelector('.cm-content')!.textContent).toContain('{#eq-ols}');
    view.destroy();
  });
});
