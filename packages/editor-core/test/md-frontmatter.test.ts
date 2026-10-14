import { describe, it, expect, beforeEach } from 'vitest';
import { EditorState } from '@codemirror/state';
import { markdown } from '@codemirror/lang-markdown';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { frontmatterSyntax } from '../src/editor/md-frontmatter';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';

function makeState(doc: string): EditorState {
  const state = EditorState.create({
    doc,
    extensions: [markdown({ extensions: [frontmatterSyntax] })],
  });
  ensureSyntaxTree(state, state.doc.length, 5000);
  return state;
}

function nodeNames(state: EditorState): string[] {
  const out: string[] = [];
  syntaxTree(state).iterate({ enter: (n) => void out.push(n.name) });
  return out;
}

const FM = '---\ntitle: "Doc"\nauthor: Chalk\n---\n\n# Body {#sec-x}';

describe('frontmatter parsing', () => {
  it('parses a leading --- … --- block as one Frontmatter node', () => {
    const state = makeState(FM);
    const names = nodeNames(state);
    expect(names).toContain('Frontmatter');
    // The closing --- must NOT be read as a Setext heading over the preamble.
    expect(names).not.toContain('SetextHeading2');
    // Body below still parses normally.
    expect(names).toContain('ATXHeading1');
  });

  it('spans from the opening --- through the closing ---', () => {
    const state = makeState(FM);
    let range: { from: number; to: number } | null = null;
    syntaxTree(state).iterate({
      enter: (n) => {
        if (n.name === 'Frontmatter') range = { from: n.from, to: n.to };
      },
    });
    expect(range).not.toBeNull();
    expect(range!.from).toBe(0);
    const closeEnd = FM.indexOf('---\n\n') + 3;
    expect(range!.to).toBe(closeEnd);
  });

  it('does not fire when --- is not the first line', () => {
    const state = makeState('# Title\n\n---\nnot: frontmatter\n---');
    expect(nodeNames(state)).not.toContain('Frontmatter');
  });
});

describe('frontmatter dim decoration', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('greys the preamble but keeps it visible and not a heading', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(parent, FM, { onContentChange: () => {} }, 'md'));
    ensureSyntaxTree(view.state, view.state.doc.length, 5000);
    view.dispatch({ selection: { anchor: view.state.doc.length } });

    const dim = view.dom.querySelector('.cm-frontmatter-dim');
    expect(dim).not.toBeNull();
    const text = view.dom.querySelector('.cm-content')!.textContent ?? '';
    expect(text).toContain('title: "Doc"'); // still shown
    view.destroy();
  });
});
