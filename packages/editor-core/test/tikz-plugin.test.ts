import { describe, it, expect, afterEach, vi } from 'vitest';
import type { EditorView } from '@codemirror/view';
import type { TikzRenderer, TikzResult } from '../src/editor/tikz-renderer';
import { destroyViews, mdView, texView } from './helpers/views';

/**
 * TikZ pictures keep their source and gain a block widget under their last
 * line. The host is faked: it answers with an image named after the request,
 * unless `answer` returns something else. The render cache is module-wide, so each
 * test draws its own picture.
 */

function fakeHost(answer?: (document: string) => TikzResult | undefined) {
  return vi.fn<TikzRenderer>(
    async (document) =>
      answer?.(document) ?? { url: `data:${encodeURIComponent(document)}`, width: 120, height: 80 },
  );
}

const tex = (body: string, preamble = '\\usepackage{amsmath}\n\\title{T}') =>
  `\\documentclass{article}\n${preamble}\n\\begin{document}\nIntro\n${body}\nAfter\n\\end{document}\n`;

const picture = (draw: string) => `\\begin{tikzpicture}\n  ${draw}\n\\end{tikzpicture}`;

function requested(view: EditorView): string | null {
  const src = view.dom.querySelector<HTMLImageElement>('.cm-tikz-figure')?.getAttribute('src');
  return src ? decodeURIComponent(src.slice('data:'.length)) : null;
}

afterEach(() => destroyViews());

describe('tex pictures', () => {
  it('renders the figure right after the \\end line, with the kept preamble', async () => {
    const renderTikz = fakeHost();
    const view = texView(tex(picture('\\draw (0,0) -- (1,0);')), { renderTikz });
    const widget = view.dom.querySelector<HTMLElement>('.cm-tikz')!;
    expect(widget.previousElementSibling?.textContent).toBe('\\end{tikzpicture}');
    await vi.waitFor(() => expect(widget.hidden).toBe(false));
    const sent = requested(view)!;
    expect(sent).toContain('\\usepackage{amsmath}');
    expect(sent).not.toContain('\\title');
    expect(sent).toContain('\\draw (0,0) -- (1,0);');
    expect(widget.querySelector<HTMLImageElement>('img')!.style.width).toBe('120px');
    expect(renderTikz).toHaveBeenCalledTimes(1);
  });

  it('leaves a tikzcd inside display math to the math widget', () => {
    const renderTikz = fakeHost();
    const view = texView(tex('\\[\n\\begin{tikzcd} A \\arrow[r] & B \\end{tikzcd}\n\\]'), { renderTikz });
    expect(view.dom.querySelector('.cm-tikz')).toBeNull();
  });

  it('stays source-only without a renderer, and in source mode', () => {
    const doc = tex(picture('\\draw (0,0) -- (2,0);'));
    expect(texView(doc).dom.querySelector('.cm-tikz')).toBeNull();
    const renderTikz = fakeHost();
    expect(texView(doc, { renderTikz, viewMode: 'source' }).dom.querySelector('.cm-tikz')).toBeNull();
    expect(texView(doc, { renderTikz, viewMode: 'mixed' }).dom.querySelector('.cm-tikz')).not.toBeNull();
  });

  it('carries the slide card through a picture in a beamer frame', () => {
    const renderTikz = fakeHost();
    const doc =
      '\\documentclass{beamer}\n\\begin{document}\n\\begin{frame}{Plot}\n' +
      picture('\\draw (0,0) -- (3,0);') +
      '\n\\end{frame}\n\\end{document}\n';
    const view = texView(doc, { renderTikz });
    expect(view.dom.querySelector('.cm-tikz')?.classList.contains('cm-slide')).toBe(true);
  });

  it('keeps the last good figure, dimmed, while an edit does not compile', async () => {
    const renderTikz = fakeHost((d) => (d.includes('BROKEN') ? { error: '! Undefined control sequence.' } : undefined));
    const view = texView(tex(picture('\\draw (0,0) -- (4,0);')), { renderTikz });
    await vi.waitFor(() => expect(requested(view)).toContain('(4,0)'));

    const at = view.state.doc.toString().indexOf('\\draw (0,0) -- (4,0);');
    view.dispatch({ changes: { from: at, insert: '\\BROKEN ' } });
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-tikz-stale')).not.toBeNull(), { timeout: 3000 });
    expect(requested(view)).not.toContain('BROKEN');
    expect(view.dom.querySelector('.cm-tikz-error')?.textContent).toContain('Undefined control sequence');
  });

  it('hides the widget when the host has no TeX', async () => {
    const renderTikz = vi.fn<TikzRenderer>(async () => null);
    const view = texView(tex(picture('\\draw (0,0) -- (5,0);')), { renderTikz });
    await vi.waitFor(() => expect(renderTikz).toHaveBeenCalledTimes(1));
    await Promise.resolve();
    expect(view.dom.querySelector<HTMLElement>('.cm-tikz')?.hidden).toBe(true);
  });
});

describe('markdown fences', () => {
  const fence = (body: string, info = 'tikz') => `Intro\n\n\`\`\`${info}\n${body}\n\`\`\`\n\nAfter\n`;

  it('renders a ```tikz fence under its closing fence', async () => {
    const renderTikz = fakeHost();
    const view = mdView(fence('\\draw (0,0) circle (1);'), { renderTikz });
    const widget = view.dom.querySelector('.cm-tikz');
    expect(widget?.previousElementSibling?.textContent).toBe('```');
    await vi.waitFor(() => expect(requested(view)).toContain('\\begin{tikzpicture}\n\\draw (0,0) circle (1);'));
  });

  it('accepts the knitr/Quarto `{tikz}` spelling and ignores other fences', () => {
    const renderTikz = fakeHost();
    expect(mdView(fence('\\draw (0,0) circle (2);', '{tikz}'), { renderTikz }).dom.querySelector('.cm-tikz')).not.toBeNull();
    expect(mdView(fence('print(1)', 'python'), { renderTikz }).dom.querySelector('.cm-tikz')).toBeNull();
  });
});
