import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from '@codemirror/view';
import { EditorState, Extension, Range, StateEffect, StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { normalizeFenceInfo } from './code-languages';
import { luminance, observeLook } from './editor-look';
import { isInMathContextTex } from './tex-math';
import { frameBlockAt } from './tex-frame-plugin';
import { tikzRendererFacet, type TikzResult } from './tikz-renderer';
import { fenceTikzDocument, localizeError, scanTexPictures, texPreamble, tikzDocument } from './tikz-source';
import '../styles/tikz.css';

// A TikZ picture keeps its source and gains the typeset figure as a block
// widget under its last line, as mermaid fences do: the caret model, reveal
// rules and Up/Down are untouched. In .tex that is a `tikzpicture`/`tikzcd`
// outside math; in Markdown a ```tikz (or Quarto/knitr ```{tikz}) fence. The
// host typesets (tikz-renderer.ts); the document it gets is built here.
//
// A StateField, not a ViewPlugin: block widgets change line heights, and CM6
// only takes block decorations from state.

// ---------------------------------------------------------------------------
//  Rendering
// ---------------------------------------------------------------------------

/** Shared across editors so a tab switch or a scroll back repaints at once. */
const renderCache = new Map<string, TikzResult>();
const RENDER_CACHE_LIMIT = 64;
/** Last painted height per document: the height map's guess before the render lands. */
const heightCache = new Map<string, number>();
/** A TeX run is costly: wait for a real pause in typing before the next. */
const EDIT_DEBOUNCE_MS = 600;
/** Per figure DOM: the latest fill, so a slow render can't overwrite a newer one. */
const fillToken = new WeakMap<HTMLElement, number>();

function remember<V>(cache: Map<string, V>, key: string, value: V): void {
  cache.delete(key);
  cache.set(key, value);
  if (cache.size > RENDER_CACHE_LIMIT) cache.delete(cache.keys().next().value as string);
}

/**
 * On error the last good figure stays, dimmed, above the message, so a
 * half-typed coordinate doesn't collapse the block on every pause.
 */
function paint(dom: HTMLElement, widget: TikzWidget, result: TikzResult): void {
  const { document } = widget;
  const img = dom.querySelector<HTMLImageElement>('.cm-tikz-figure')!;
  const caption = dom.querySelector<HTMLElement>('.cm-tikz-error')!;
  const error = 'error' in result ? localizeError(result.error, document, widget.firstLine) : null;
  if ('url' in result) {
    img.src = result.url;
    // The box takes its size before the image decodes, so the height map is
    // right on the first measure; max-width scales a wide figure down whole.
    img.style.width = `${result.width}px`;
    img.style.aspectRatio = `${result.width} / ${result.height}`;
    img.hidden = false;
  }
  dom.classList.toggle('cm-tikz-stale', error !== null && !img.hidden);
  caption.textContent = error ?? '';
  caption.hidden = error === null;
  dom.hidden = false;
  if (dom.isConnected) remember(heightCache, document, dom.getBoundingClientRect().height);
}

class TikzWidget extends WidgetType {
  constructor(
    /** The whole standalone document: the render and cache key. */
    readonly document: string,
    /** Inside a beamer frame: carry the slide card's side edges (frameBlockAt). */
    readonly frame: boolean,
    /** The line of `\begin{…}` in a .tex file, for the error's line number. */
    readonly firstLine: number | null,
  ) {
    super();
  }

  eq(other: TikzWidget): boolean {
    return other.document === this.document && other.frame === this.frame && other.firstLine === this.firstLine;
  }

  get estimatedHeight(): number {
    return heightCache.get(this.document) ?? -1;
  }

  toDOM(view: EditorView): HTMLElement {
    const dom = document.createElement('div');
    dom.className = this.frame ? 'cm-tikz cm-slide' : 'cm-tikz';
    // Nothing to show until the first answer: no empty padded strip.
    dom.hidden = true;
    const img = document.createElement('img');
    img.className = 'cm-tikz-figure';
    img.alt = '';
    img.draggable = false;
    img.hidden = true;
    const caption = document.createElement('div');
    caption.className = 'cm-tikz-error';
    caption.hidden = true;
    dom.append(img, caption);
    this.fill(dom, view, 0);
    return dom;
  }

  /** Keep the old figure up while the edited source renders. */
  updateDOM(dom: HTMLElement, view: EditorView, from: TikzWidget): boolean {
    dom.classList.toggle('cm-slide', this.frame);
    this.fill(dom, view, from.document !== this.document ? EDIT_DEBOUNCE_MS : 0);
    return true;
  }

  private fill(dom: HTMLElement, view: EditorView, delay: number): void {
    const token = (fillToken.get(dom) ?? 0) + 1;
    fillToken.set(dom, token);
    const current = (): boolean => fillToken.get(dom) === token;
    const { document } = this;

    // A cached render paints synchronously: no empty frame, no height jump.
    const hit = renderCache.get(document);
    if (hit) {
      paint(dom, this, hit);
      return;
    }

    const run = async (): Promise<void> => {
      const render = view.state.facet(tikzRendererFacet);
      if (!current() || !render) return;
      let result: TikzResult | null;
      try {
        result = await render(document);
      } catch (e) {
        result = { error: e instanceof Error ? e.message : String(e) };
      }
      // No TeX on this machine: the source alone, as without a renderer.
      if (result === null) {
        if (current()) dom.hidden = true;
        return;
      }
      remember(renderCache, document, result);
      if (!current()) return;
      paint(dom, this, result);
      view.requestMeasure();
    };
    if (delay > 0) setTimeout(() => void run(), delay);
    else void run();
  }
}

// ---------------------------------------------------------------------------
//  Decorations
// ---------------------------------------------------------------------------

function widgetAt(state: EditorState, line: number, widget: TikzWidget): Range<Decoration> {
  return Decoration.widget({ widget, block: true, side: 1 }).range(state.doc.line(line).to);
}

function buildTexDecorations(state: EditorState): DecorationSet {
  if (!state.facet(tikzRendererFacet)) return Decoration.none;
  const { pictures, bodyStart } = scanTexPictures(state.doc);
  if (pictures.length === 0) return Decoration.none;
  const preamble = bodyStart === -1 ? null : texPreamble(state.doc.sliceString(0, bodyStart));
  const decorations: Range<Decoration>[] = [];
  for (const p of pictures) {
    // A `tikzcd` in `\[…\]` belongs to the math widget.
    if (isInMathContextTex(state, p.from)) continue;
    const document = tikzDocument(state.doc.sliceString(p.from, p.to), preamble);
    const frame = frameBlockAt(state.doc, p.from, p.to);
    const widget = new TikzWidget(document, frame, state.doc.lineAt(p.from).number);
    decorations.push(widgetAt(state, p.endLine, widget));
  }
  return Decoration.set(decorations);
}

function buildMdDecorations(state: EditorState): DecorationSet {
  if (!state.facet(tikzRendererFacet)) return Decoration.none;
  const decorations: Range<Decoration>[] = [];
  const { doc } = state;
  syntaxTree(state).iterate({
    enter(node) {
      if (node.name === 'Paragraph') return false; // inline content only
      if (node.name !== 'FencedCode') return undefined;
      const info = node.node.getChild('CodeInfo');
      if (!info || normalizeFenceInfo(doc.sliceString(info.from, info.to)) !== 'tikz') return false;
      // An unclosed fence runs to the end of the document: no figure.
      if (node.node.getChildren('CodeMark').length < 2) return false;
      const body = node.node.getChild('CodeText');
      const source = body ? doc.sliceString(body.from, body.to) : '';
      if (!source.trim()) return false;
      const widget = new TikzWidget(fenceTikzDocument(source), false, null);
      decorations.push(widgetAt(state, doc.lineAt(node.to).number, widget));
      return false;
    },
  });
  return Decoration.set(decorations);
}

function tikzField(language: 'tex' | 'md'): StateField<DecorationSet> {
  const build = language === 'tex' ? buildTexDecorations : buildMdDecorations;
  return StateField.define<DecorationSet>({
    create: build,
    update(value, tr) {
      // Markdown also on background parse progress, so fences below the
      // first parse window get their figure (as in the mermaid field).
      const reparsed = language === 'md' && syntaxTree(tr.state) !== syntaxTree(tr.startState);
      return tr.docChanged || reparsed ? build(tr.state) : value;
    },
    provide: (f) => EditorView.decorations.from(f),
  });
}

// ---------------------------------------------------------------------------
//  Dark look
// ---------------------------------------------------------------------------

// TeX draws black on transparent. On a dark editor the figure is inverted
// with its hues turned back (tikz.css), which keeps colours recognisable;
// a class on the editor root, so the cached figures need no re-render.
const setDark = StateEffect.define<boolean>();

const DARK_ATTRS: Record<string, string> = { class: 'cm-tikz-dark' };
const NO_ATTRS: Record<string, string> = {};

const darkField = StateField.define<boolean>({
  create: () => false,
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setDark)) value = e.value;
    return value;
  },
  provide: (f) => EditorView.editorAttributes.from(f, (dark) => (dark ? DARK_ATTRS : NO_ATTRS)),
});

const darkWatcher = ViewPlugin.fromClass(
  class {
    private readonly stop: (() => void) | null = null;
    // A detached view has no computed style yet: skip until it is attached.
    private readonly check = (): void => {
      if (!this.view.dom.isConnected) return;
      const dark = luminance(getComputedStyle(this.view.contentDOM).color) > 0.5;
      if (dark !== this.view.state.field(darkField)) this.view.dispatch({ effects: setDark.of(dark) });
    };

    constructor(private readonly view: EditorView) {
      if (!view.state.facet(tikzRendererFacet)) return;
      this.stop = observeLook(this.check);
      // A dispatch can't run inside construction.
      setTimeout(this.check, 0);
    }

    update(update: ViewUpdate): void {
      // New theme styles apply after this update; compare once they have.
      if (this.stop && update.transactions.some((tr) => tr.reconfigured)) setTimeout(this.check, 0);
    }

    destroy(): void {
      this.stop?.();
    }
  },
);

/** Figures under TikZ pictures. Inert until a host provides a renderer. */
export function tikzPlugin(language: 'tex' | 'md'): Extension {
  return [tikzField(language), darkField, darkWatcher];
}
