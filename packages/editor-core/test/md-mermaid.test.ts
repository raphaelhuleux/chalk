import { describe, it, expect, afterEach, vi } from 'vitest';
import type { EditorView } from '@codemirror/view';
import { scriptMermaidLoader, type MermaidLoader } from '../src/editor/md-mermaid-plugin';
import { MERMAID_GLOBAL, type MermaidRenderer } from '../src/editor/mermaid-api';
import { destroyViews, mdView } from './helpers/views';

/**
 * ```mermaid fences keep their source and gain a block widget under the
 * closing fence. The renderer is faked: real mermaid needs layout (getBBox)
 * that jsdom lacks, so Tests/browser drives the built script instead.
 *
 * The render cache is module-wide, so each test uses its own diagram source.
 */

function fakeRenderer(fail?: (source: string) => boolean) {
  const render = vi.fn(async (source: string) => {
    if (fail?.(source)) throw new Error(`Parse error in ${source.split('\n')[0]}`);
    return `<svg data-source="${encodeURIComponent(source)}"></svg>`;
  });
  const renderer: MermaidRenderer = { render };
  const loadMermaid: MermaidLoader = () => Promise.resolve(renderer);
  return { render, loadMermaid };
}

const fence = (body: string, info = 'mermaid') => `Intro\n\n\`\`\`${info}\n${body}\n\`\`\`\n\nAfter\n`;

function svgSource(view: EditorView): string | null {
  const svg = view.dom.querySelector('.cm-mermaid-diagram svg');
  const encoded = svg?.getAttribute('data-source');
  return encoded == null ? null : decodeURIComponent(encoded);
}

afterEach(() => destroyViews());

describe('mermaid fences', () => {
  it('renders the diagram in a block widget right after the closing fence', async () => {
    const { render, loadMermaid } = fakeRenderer();
    const view = mdView(fence('graph TD\n  A --> B'), { loadMermaid });
    const widget = view.dom.querySelector('.cm-mermaid');
    expect(widget).not.toBeNull();
    expect(widget!.previousElementSibling?.textContent).toBe('```');
    await vi.waitFor(() => expect(svgSource(view)).toBe('graph TD\n  A --> B'));
    expect(render).toHaveBeenCalledTimes(1);
  });

  it('accepts the Quarto `{mermaid}` spelling', async () => {
    const { loadMermaid } = fakeRenderer();
    const view = mdView(fence('graph LR\n  Q --> R', '{mermaid}'), { loadMermaid });
    await vi.waitFor(() => expect(svgSource(view)).toBe('graph LR\n  Q --> R'));
  });

  it('ignores other languages, unclosed fences and empty fences', () => {
    const { render, loadMermaid } = fakeRenderer();
    for (const doc of [
      fence('print(1)', 'python'),
      'Intro\n\n```mermaid\ngraph TD\n  open --> fence\n',
      fence('   '),
    ]) {
      const view = mdView(doc, { loadMermaid });
      expect(view.dom.querySelector('.cm-mermaid')).toBeNull();
    }
    expect(render).not.toHaveBeenCalled();
  });

  it('stays plain code when the host provides no loader', () => {
    const view = mdView(fence('graph TD\n  no --> loader'));
    expect(view.dom.querySelector('.cm-mermaid')).toBeNull();
  });

  it('renders in mixed mode but not in source mode', () => {
    const { loadMermaid } = fakeRenderer();
    const doc = fence('graph TD\n  mode --> test');
    expect(mdView(doc, { loadMermaid, viewMode: 'mixed' }).dom.querySelector('.cm-mermaid')).not.toBeNull();
    expect(mdView(doc, { loadMermaid, viewMode: 'source' }).dom.querySelector('.cm-mermaid')).toBeNull();
  });

  it('does not re-render when an edit lands outside the fence', async () => {
    const { render, loadMermaid } = fakeRenderer();
    const view = mdView(fence('graph TD\n  stable --> widget'), { loadMermaid });
    await vi.waitFor(() => expect(render).toHaveBeenCalledTimes(1));
    view.dispatch({ changes: { from: view.state.doc.length, insert: 'more prose\n' } });
    await new Promise((r) => setTimeout(r, 300));
    expect(render).toHaveBeenCalledTimes(1);
    expect(svgSource(view)).toBe('graph TD\n  stable --> widget');
  });

  it('shows the parse error when there is no earlier diagram', async () => {
    const { loadMermaid } = fakeRenderer(() => true);
    const view = mdView(fence('graph TD\n  broken -->'), { loadMermaid });
    await vi.waitFor(() => {
      const caption = view.dom.querySelector<HTMLElement>('.cm-mermaid-error');
      expect(caption?.hidden).toBe(false);
      expect(caption?.textContent).toContain('Parse error');
    });
    expect(view.dom.querySelector('.cm-mermaid-stale')).toBeNull();
  });

  it('keeps the last good diagram, dimmed, while an edit does not parse', async () => {
    const { render, loadMermaid } = fakeRenderer((s) => s.includes('-->\n') || s.endsWith('-->'));
    const view = mdView(fence('graph TD\n  edit --> me'), { loadMermaid });
    await vi.waitFor(() => expect(svgSource(view)).toBe('graph TD\n  edit --> me'));

    // Delete the edge target: the source now ends in a dangling arrow.
    const at = view.state.doc.toString().indexOf(' me\n```');
    view.dispatch({ changes: { from: at, to: at + 3 } });
    await vi.waitFor(() => expect(view.dom.querySelector('.cm-mermaid-stale')).not.toBeNull());
    expect(svgSource(view)).toBe('graph TD\n  edit --> me');
    expect(view.dom.querySelector<HTMLElement>('.cm-mermaid-error')?.hidden).toBe(false);
    expect(render).toHaveBeenCalledTimes(2);

    // Fixing it clears the error and swaps the diagram in the same DOM.
    const widget = view.dom.querySelector('.cm-mermaid');
    const end = view.state.doc.toString().indexOf('\n```', at - 4);
    view.dispatch({ changes: { from: end, insert: ' fixed' } });
    await vi.waitFor(() => expect(svgSource(view)).toBe('graph TD\n  edit --> fixed'));
    expect(view.dom.querySelector('.cm-mermaid-stale')).toBeNull();
    expect(view.dom.querySelector<HTMLElement>('.cm-mermaid-error')?.hidden).toBe(true);
    expect(view.dom.querySelector('.cm-mermaid')).toBe(widget);
  });

  it('says so, and keeps the code block, when the script does not load', async () => {
    const view = mdView(fence('graph TD\n  load --> fails'), { loadMermaid: () => Promise.resolve(null) });
    await vi.waitFor(() =>
      expect(view.dom.querySelector('.cm-mermaid-error')?.textContent).toContain('did not load'),
    );
    expect(view.dom.querySelector('.cm-mermaid svg')).toBeNull();
    expect(view.dom.querySelector('.cm-codeblock')).not.toBeNull();
  });
});

describe('scriptMermaidLoader', () => {
  afterEach(() => {
    delete (globalThis as Record<string, unknown>)[MERMAID_GLOBAL];
    document.head.querySelectorAll('script').forEach((s) => s.remove());
  });

  it('injects one script with the nonce and resolves with the registered renderer', async () => {
    const load = scriptMermaidLoader('mermaid.js', 'n0nce');
    const first = load();
    const second = load();
    const scripts = document.head.querySelectorAll('script');
    expect(scripts).toHaveLength(1);
    expect(scripts[0].getAttribute('src')).toBe('mermaid.js');
    expect(scripts[0].nonce).toBe('n0nce');

    const renderer: MermaidRenderer = { render: () => Promise.resolve('<svg></svg>') };
    (globalThis as Record<string, unknown>)[MERMAID_GLOBAL] = renderer;
    scripts[0].dispatchEvent(new Event('load'));
    expect(await first).toBe(renderer);
    expect(await second).toBe(renderer);
  });

  it('resolves null when the script fails to load', async () => {
    const pending = scriptMermaidLoader('missing.js')();
    document.head.querySelector('script')!.dispatchEvent(new Event('error'));
    expect(await pending).toBeNull();
  });
});
