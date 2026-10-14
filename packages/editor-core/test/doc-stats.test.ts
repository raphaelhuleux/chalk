import { describe, it, expect, afterEach } from 'vitest';
import { EditorSelection } from '@codemirror/state';
import { documentStats } from '../src/editor/doc-stats';
import { destroyViews, mdView, texView } from './helpers/views';

afterEach(destroyViews);

const tex = (doc: string) => documentStats(texView(doc).state, 'tex');
const md = (doc: string) => documentStats(mdView(doc).state, 'md');

describe('documentStats: LaTeX', () => {
  it('counts prose words, not commands, math or comments', () => {
    const s = tex(
      [
        '\\section{Stylized facts}\\label{sec:facts}',
        'The top 1\\% share rose; see Figure~\\ref{fig:a} and \\citet{piketty2018}.',
        '% a comment that does not count',
        'With $a_1 > z$ and \\[ x^2 \\] we \\emph{conclude}.',
      ].join('\n'),
    );
    // Stylized facts | The top 1 share rose see Figure and | With and we conclude
    expect(s.words).toBe(2 + 8 + 4);
  });

  it('counts only the body when the file has one', () => {
    const s = tex(
      ['\\documentclass{article}', '\\title{Not counted}', '\\begin{document}', 'Two words', '\\end{document}', 'after'].join(
        '\n',
      ),
    );
    expect(s.words).toBe(2);
  });

  it('characters exclude spaces and markup', () => {
    expect(tex('\\textbf{ab} cd~ef').characters).toBe(6);
  });

  it('a selection reports its own words', () => {
    const view = texView('one two three four');
    view.dispatch({ selection: EditorSelection.range(4, 13) });
    expect(documentStats(view.state, 'tex')).toMatchObject({ words: 4, selectionWords: 2 });
    view.dispatch({ selection: EditorSelection.cursor(0) });
    expect(documentStats(view.state, 'tex').selectionWords).toBeNull();
  });

  it("joins don't, well-known and 3.5 into one word each", () => {
    expect(tex("don't well-known 3.5").words).toBe(3);
  });
});

describe('documentStats: Markdown', () => {
  it('skips front matter, code, math, link targets and Quarto syntax', () => {
    const s = md(
      [
        '---',
        'title: Not counted',
        '---',
        '# Heading {#sec-intro}',
        '',
        'A [link](https://example.com) and $x^2$ and `code` here, see @sec-intro.',
        '',
        '::: {#thm-a name="T"}',
        'Inside text.',
        ':::',
        '',
        '```python',
        'not counted at all',
        '```',
      ].join('\n'),
    );
    // Heading | A link and and here see | Inside text
    expect(s.words).toBe(1 + 6 + 2);
  });
});
