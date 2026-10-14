import { describe, it, expect } from 'vitest';
import { parseTexEnvOpen } from '../src/editor/tex-callout-plugin';

/**
 * beamer's block family reuses the callout renderer wholesale — it is the same
 * shape of object (a titled box) and the hosts must draw it identically. The
 * only new thing is the surface syntax: beamer takes its title in a BRACE
 * argument where amsthm takes it in brackets.
 */

describe('beamer block environments as callouts', () => {
  it('recognises \\begin{block}{Title} with a brace title', () => {
    const open = parseTexEnvOpen('\\begin{block}{Takeaway}');
    expect(open?.type).toBe('block');
    expect(open?.title).toBe('Takeaway');
  });

  it('recognises alertblock and exampleblock', () => {
    expect(parseTexEnvOpen('\\begin{alertblock}{Warning}')?.type).toBe('alertblock');
    expect(parseTexEnvOpen('\\begin{exampleblock}{Example}')?.type).toBe('exampleblock');
  });

  it('never numbers a block — the title is the whole label', () => {
    expect(parseTexEnvOpen('\\begin{block}{Takeaway}')?.numbered).toBe(false);
  });

  it('accepts a block with no title at all', () => {
    const open = parseTexEnvOpen('\\begin{block}{}');
    expect(open?.type).toBe('block');
    expect(open?.title).toBe('');
  });

  it('does NOT widen the brace-title form to other environments', () => {
    // The regression this guards: accepting `{…}` for every env turns
    // \begin{minipage}{0.45\textwidth} into a callout.
    expect(parseTexEnvOpen('\\begin{minipage}{0.45\\textwidth}')).toBeNull();
    expect(parseTexEnvOpen('\\begin{column}{0.5\\textwidth}')).toBeNull();
  });

  it('leaves the bracket-title form working for the theorem family', () => {
    const open = parseTexEnvOpen('\\begin{theorem}[Pythagoras]');
    expect(open?.type).toBe('theorem');
    expect(open?.title).toBe('Pythagoras');
    expect(open?.numbered).toBe(true);
  });
});

describe('block heading rendering', () => {
  it('shows the title as the box heading, with no environment name', async () => {
    const { createEditor } = await import('../src/editor/setup');
    const { parsed } = await import('./helpers/force-parse');
    document.body.innerHTML = '';
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(
      createEditor(
        parent,
        '\\begin{block}{Takeaway}\nconjugate\n\\end{block}\nafter',
        { onContentChange: () => {} },
        'tex',
      ),
    );
    view.dispatch({ selection: { anchor: view.state.doc.length } });
    const label = view.dom.querySelector('.cm-callout-label');
    expect(label?.textContent).toBe('Takeaway');
    // A theorem would read "Theorem 1 (Pythagoras)"; a block is just its title.
    expect(label?.textContent).not.toContain('Block');
    view.destroy();
  });
});
