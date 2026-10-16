import { describe, it, expect, beforeEach, vi } from 'vitest';
import { mockPort } from './helpers/views';
import { EditorView } from '@codemirror/view';
import { mountEditor } from '../src/index';

const TINY_PNG =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/**
 * Image live preview across both languages: the widget renders, the host
 * resolver is consulted for local paths, width options apply, and — the
 * regression that motivated the guards — a node spanning a line break must
 * fall back to raw source instead of throwing CM6's "Decorations that
 * replace line breaks may not be specified via plugins".
 */
describe('image live preview', () => {
  let root: HTMLElement;

  beforeEach(() => {
    document.body.innerHTML = '';
    root = document.createElement('div');
    document.body.appendChild(root);
  });

  function mount(text: string, language: 'md' | 'tex', resolveAsset?: (src: string) => Promise<string | null>) {
    const mock = mockPort();
    mountEditor({ root, port: mock.port, resolveAsset });
    mock.push({ type: 'init', text, language });
    const view = EditorView.findFromDOM(root);
    if (!view) throw new Error('no EditorView mounted');
    return { view, mock };
  }

  it('renders a markdown image widget and consults the resolver', async () => {
    const resolver = vi.fn(() => Promise.resolve(TINY_PNG));
    mount('intro\n\n![plot](figures/plot.png)\n', 'md', resolver);
    const widget = root.querySelector('.cm-live-image');
    expect(widget).not.toBeNull();
    await vi.waitFor(() => expect(resolver).toHaveBeenCalledWith('figures/plot.png'));
    await vi.waitFor(() => {
      const img = root.querySelector('.cm-live-image img') as HTMLImageElement | null;
      expect(img?.src).toBe(TINY_PNG);
    });
  });

  /** Lines whose image is centred: the ones holding nothing but the image. */
  function centredLines(): string[] {
    return [...root.querySelectorAll('.cm-line.cm-live-image-line')].map((l) => l.textContent ?? '');
  }

  it('centres a markdown image alone on its line, with or without a Quarto attribute block', () => {
    mount('intro\n\n![a](a.png)\n\n  ![b](b.png){width=50%}\n\nsee ![c](c.png) here\n\n- ![d](d.png)\n', 'md', () =>
      Promise.resolve(TINY_PNG),
    );
    expect(root.querySelectorAll('.cm-live-image').length).toBe(4);
    expect(centredLines().length).toBe(2);
  });

  it('centres a lone includegraphics, a trailing comment allowed, and not one inside prose', () => {
    mount(
      'text\n\\includegraphics{a}\n\n  \\includegraphics[width=0.5\\textwidth]{b} % fig\n\nsee \\includegraphics{c} here\n',
      'tex',
      () => Promise.resolve(TINY_PNG),
    );
    expect(root.querySelectorAll('.cm-live-image').length).toBe(3);
    expect(centredLines().length).toBe(2);
  });

  it('drops the centring with the widget when the caret reveals the source', () => {
    const { view } = mount('intro\n\n![a](a.png)\n', 'md', () => Promise.resolve(TINY_PNG));
    expect(centredLines().length).toBe(1);
    view.dispatch({ selection: { anchor: view.state.doc.toString().indexOf('a.png') } });
    expect(root.querySelector('.cm-live-image')).toBeNull();
    expect(centredLines().length).toBe(0);
  });

  it('leaves a multi-line markdown image as raw source without throwing', () => {
    const { view } = mount('![alt\nwrapped](figures/plot.png)\n', 'md');
    expect(root.querySelector('.cm-live-image')).toBeNull();
    expect(view.state.doc.toString()).toContain('![alt');
  });

  it('renders a tex includegraphics widget with a percentage width', async () => {
    mount('text\n\\includegraphics[width=0.5\\textwidth]{plot}\n', 'tex', () =>
      Promise.resolve(TINY_PNG),
    );
    const widget = root.querySelector('.cm-live-image');
    expect(widget).not.toBeNull();
    await vi.waitFor(() => {
      const img = root.querySelector('.cm-live-image img') as HTMLImageElement | null;
      expect(img?.style.width).toBe('50%');
    });
  });

  it('leaves a line-wrapped includegraphics as raw source without throwing', () => {
    mount('\\includegraphics[width=0.5\\textwidth\n]{plot.png}\n', 'tex');
    expect(root.querySelector('.cm-live-image')).toBeNull();
  });

  it('does not preview a commented-out includegraphics', () => {
    mount('% \\includegraphics{plot.png}\n', 'tex');
    expect(root.querySelector('.cm-live-image')).toBeNull();
  });

  it('reveals the raw tex command when the cursor moves inside it', () => {
    const text = 'before\n\\includegraphics{plot.png}\nafter\n';
    const { view } = mount(text, 'tex');
    expect(root.querySelector('.cm-live-image')).not.toBeNull();
    view.dispatch({ selection: { anchor: text.indexOf('plot') } });
    expect(root.querySelector('.cm-live-image')).toBeNull();
  });

  it('shows the missing placeholder when the resolver returns null', async () => {
    mount('intro\n\n![gone](missing.png)\n', 'md', () => Promise.resolve(null));
    await vi.waitFor(() => {
      expect(root.querySelector('.cm-live-image-missing')).not.toBeNull();
    });
  });
});
