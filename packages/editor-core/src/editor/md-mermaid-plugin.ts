import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from '@codemirror/view';
import { EditorState, Extension, Facet, Range, StateEffect, StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { normalizeFenceInfo } from './code-languages';
import { openExternal } from '../host-port';
import { MERMAID_GLOBAL, type MermaidRenderer, type MermaidTheme } from './mermaid-api';
import '../styles/mermaid.css';

// A ```mermaid fence keeps its source and gains the rendered diagram below its
// closing fence: a block widget after the last line, so the caret model, the
// reveal rules and Up/Down are untouched. An unclosed fence renders nothing.
//
// A StateField, not a ViewPlugin: block widgets change line heights, and CM6
// only takes block decorations from state.

/** Resolves to null when the renderer can't load; fences then stay plain code. */
export type MermaidLoader = () => Promise<MermaidRenderer | null>;

/** Host-supplied. Without one, mermaid fences render as ordinary code blocks. */
export const mermaidLoaderFacet = Facet.define<MermaidLoader, MermaidLoader | null>({
  combine: (values) => values[0] ?? null,
});

/**
 * Injects `<script src>` on the first call and resolves with the renderer that
 * script registers (src/mermaid-entry.ts). `nonce`: VS Code's CSP admits only
 * scripts carrying the page's nonce.
 */
export function scriptMermaidLoader(src: string, nonce?: string): MermaidLoader {
  let pending: Promise<MermaidRenderer | null> | null = null;
  return () => {
    pending ??= new Promise((resolve) => {
      const script = document.createElement('script');
      script.src = src;
      if (nonce) script.nonce = nonce;
      script.onload = () =>
        resolve(((globalThis as Record<string, unknown>)[MERMAID_GLOBAL] as MermaidRenderer) ?? null);
      script.onerror = () => resolve(null);
      document.head.appendChild(script);
    });
    return pending;
  };
}

// ---------------------------------------------------------------------------
//  Rendering
// ---------------------------------------------------------------------------

interface Rendered {
  svg: string | null;
  error: string | null;
}

/** Shared across editors so a tab switch or a scroll back repaints at once. */
const renderCache = new Map<string, Rendered>();
const RENDER_CACHE_LIMIT = 64;
/** Last painted height per source: the height map's guess before the render lands. */
const heightCache = new Map<string, number>();
/** While typing in the fence, wait for a pause before re-rendering. */
const EDIT_DEBOUNCE_MS = 250;
/** Per diagram DOM: the latest fill, so a slow render can't overwrite a newer one. */
const fillToken = new WeakMap<HTMLElement, number>();

function remember<V>(cache: Map<string, V>, key: string, value: V): void {
  cache.delete(key);
  cache.set(key, value);
  if (cache.size > RENDER_CACHE_LIMIT) cache.delete(cache.keys().next().value as string);
}

/** Relative luminance of a computed `rgb(…)` colour; 0 when unparseable. */
function luminance(color: string): number {
  const m = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/.exec(color);
  if (!m) return 0;
  const [r, g, b] = [m[1], m[2], m[3]].map((c) => {
    const s = Number(c) / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** The editor's look, or null while the view is detached (nothing computed yet). */
function readTheme(view: EditorView): MermaidTheme | null {
  if (!view.dom.isConnected) return null;
  const style = getComputedStyle(view.contentDOM);
  return { dark: luminance(style.color) > 0.5, fontFamily: style.fontFamily };
}

function themeKey(theme: MermaidTheme): string {
  return `${theme.dark ? 'dark' : 'light'}|${theme.fontFamily}`;
}

function errorText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** Links in a diagram go to the host's browser, never navigate the editor page. */
function onDiagramClick(event: MouseEvent): void {
  const link = (event.target as Element | null)?.closest?.('a');
  if (!link) return;
  event.preventDefault();
  const href = link.getAttribute('href') ?? link.getAttribute('xlink:href');
  if (href && /^https?:/i.test(href)) openExternal(href);
}

/**
 * On error the last good diagram stays, dimmed, above the message, so a
 * half-typed edge doesn't collapse the block on every pause.
 */
function paint(dom: HTMLElement, source: string, result: Rendered): void {
  const diagram = dom.querySelector<HTMLElement>('.cm-mermaid-diagram')!;
  const caption = dom.querySelector<HTMLElement>('.cm-mermaid-error')!;
  if (result.svg !== null) diagram.innerHTML = result.svg;
  dom.classList.toggle('cm-mermaid-stale', result.error !== null && diagram.childElementCount > 0);
  caption.textContent = result.error ?? '';
  caption.hidden = result.error === null;
  if (dom.isConnected) remember(heightCache, source, dom.getBoundingClientRect().height);
}

class MermaidWidget extends WidgetType {
  constructor(
    readonly source: string,
    /** Bumped on a theme change, so every diagram re-renders. */
    readonly themeGeneration: number,
  ) {
    super();
  }

  eq(other: MermaidWidget): boolean {
    return other.source === this.source && other.themeGeneration === this.themeGeneration;
  }

  get estimatedHeight(): number {
    return heightCache.get(this.source) ?? -1;
  }

  toDOM(view: EditorView): HTMLElement {
    const dom = document.createElement('div');
    dom.className = 'cm-mermaid';
    const diagram = document.createElement('div');
    diagram.className = 'cm-mermaid-diagram';
    const caption = document.createElement('div');
    caption.className = 'cm-mermaid-error';
    caption.hidden = true;
    dom.append(diagram, caption);
    dom.addEventListener('click', onDiagramClick);
    this.fill(dom, view, 0);
    return dom;
  }

  /** Keep the old diagram up while the edited source renders. */
  updateDOM(dom: HTMLElement, view: EditorView, from: MermaidWidget): boolean {
    const edited = from.source !== this.source;
    this.fill(dom, view, edited ? EDIT_DEBOUNCE_MS : 0);
    return true;
  }

  private fill(dom: HTMLElement, view: EditorView, delay: number): void {
    const token = (fillToken.get(dom) ?? 0) + 1;
    fillToken.set(dom, token);
    const current = (): boolean => fillToken.get(dom) === token;

    // A cached render paints synchronously: no empty frame, no height jump.
    const theme = readTheme(view);
    const hit = theme && renderCache.get(`${themeKey(theme)}\n${this.source}`);
    if (hit) {
      paint(dom, this.source, hit);
      return;
    }

    const run = async (): Promise<void> => {
      if (!current()) return;
      const renderer = await view.state.facet(mermaidLoaderFacet)?.();
      if (!current()) return;
      if (!renderer) {
        paint(dom, this.source, { svg: null, error: 'Diagram preview unavailable: mermaid.js did not load.' });
        return;
      }
      // Read after the load: on the first build the view wasn't attached yet.
      const settled = readTheme(view);
      if (!settled) return;
      const key = `${themeKey(settled)}\n${this.source}`;
      let result = renderCache.get(key);
      if (!result) {
        try {
          result = { svg: await renderer.render(this.source, settled), error: null };
        } catch (e) {
          result = { svg: null, error: errorText(e) };
        }
        remember(renderCache, key, result);
      }
      if (!current()) return;
      paint(dom, this.source, result);
      view.requestMeasure();
    };
    if (delay > 0) setTimeout(() => void run(), delay);
    else void run();
  }
}

// ---------------------------------------------------------------------------
//  Decorations
// ---------------------------------------------------------------------------

const themeChanged = StateEffect.define<null>();

interface MermaidDecorations {
  themeGeneration: number;
  decorations: DecorationSet;
}

function buildMermaidDecorations(state: EditorState, themeGeneration: number): DecorationSet {
  if (!state.facet(mermaidLoaderFacet)) return Decoration.none;
  const decorations: Range<Decoration>[] = [];
  const { doc } = state;
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name === 'Paragraph') return false; // inline content only
      if (node.name !== 'FencedCode') return undefined;
      const info = node.node.getChild('CodeInfo');
      if (!info || normalizeFenceInfo(doc.sliceString(info.from, info.to)) !== 'mermaid') return false;
      // An unclosed fence runs to the end of the document: no diagram.
      if (node.node.getChildren('CodeMark').length < 2) return false;
      const body = node.node.getChild('CodeText');
      const source = body ? doc.sliceString(body.from, body.to) : '';
      if (!source.trim()) return false;
      const widget = new MermaidWidget(source, themeGeneration);
      decorations.push(Decoration.widget({ widget, block: true, side: 1 }).range(doc.lineAt(node.to).to));
      return false;
    },
  });
  return Decoration.set(decorations);
}

const mermaidField = StateField.define<MermaidDecorations>({
  create: (state) => ({ themeGeneration: 0, decorations: buildMermaidDecorations(state, 0) }),
  update(value, tr) {
    let { themeGeneration } = value;
    for (const e of tr.effects) if (e.is(themeChanged)) themeGeneration++;
    // Also on background parse progress, so fences below the first parse
    // window get their diagram (as in codeBlockField).
    if (
      themeGeneration !== value.themeGeneration ||
      tr.docChanged ||
      syntaxTree(tr.state) !== syntaxTree(tr.startState)
    ) {
      return { themeGeneration, decorations: buildMermaidDecorations(tr.state, themeGeneration) };
    }
    return value;
  },
  provide: (f) => EditorView.decorations.from(f, (v) => v.decorations),
});

/**
 * Re-renders every diagram when the editor's look changes: the native host
 * flips `data-theme` / `data-palette` on <html>, VS Code swaps <body> classes,
 * and an editor-config push reconfigures the font.
 */
const themeWatcher = ViewPlugin.fromClass(
  class {
    private key: string | null = null;
    private readonly observer: MutationObserver | null = null;
    private readonly media: MediaQueryList | null = null;
    // A detached view reads null, so a check that fires after destroy is inert.
    private readonly check = (): void => {
      const theme = readTheme(this.view);
      if (!theme) return;
      const key = themeKey(theme);
      if (this.key !== null && key !== this.key) this.view.dispatch({ effects: themeChanged.of(null) });
      this.key = key;
    };

    constructor(private readonly view: EditorView) {
      if (!view.state.facet(mermaidLoaderFacet)) return;
      this.observer = new MutationObserver(this.check);
      const attributeFilter = ['class', 'style', 'data-theme', 'data-palette'];
      this.observer.observe(document.documentElement, { attributes: true, attributeFilter });
      this.observer.observe(document.body, { attributes: true, attributeFilter });
      this.media = typeof matchMedia === 'function' ? matchMedia('(prefers-color-scheme: dark)') : null;
      this.media?.addEventListener('change', this.check);
      // Seed once the view is attached; a dispatch can't run inside construction.
      setTimeout(this.check, 0);
    }

    update(update: ViewUpdate): void {
      // New theme styles apply after this update; compare once they have.
      if (this.observer && update.transactions.some((tr) => tr.reconfigured)) setTimeout(this.check, 0);
    }

    destroy(): void {
      this.observer?.disconnect();
      this.media?.removeEventListener('change', this.check);
    }
  },
);

/** Diagrams under ```mermaid fences. Inert until a host provides a loader. */
export function mermaidPlugin(): Extension {
  return [mermaidField, themeWatcher];
}
