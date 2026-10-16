import { Decoration, EditorView, WidgetType } from '@codemirror/view';
import type { Line } from '@codemirror/state';
import { assetResolverFacet } from './asset-resolver';

/** Centres a line that holds one previewed image and nothing else. */
export const LONE_IMAGE_LINE = Decoration.line({ class: 'cm-live-image-line' });

/**
 * Whether the image at `from..to` is alone on `line`: only whitespace before it, and after
 * it only whitespace or what `trailing` allows (a Quarto `{width=…}` block, a TeX comment).
 * An image inside a sentence or a list item stays where the text puts it.
 */
export function isLoneImage(line: Line, from: number, to: number, trailing: RegExp): boolean {
  return /^\s*$/.test(line.text.slice(0, from - line.from)) && trailing.test(line.text.slice(to - line.from));
}

/**
 * An inline image (`![alt](src)` or `\includegraphics{src}`). http(s)/data
 * URLs load directly; paths go to the host's assetResolverFacet (null: missing).
 * `eq()` lets CM6 reuse the DOM, so the resolver runs once per image; `load`
 * re-measures because the height is unknown until decode.
 */
export class ImageWidget extends WidgetType {
  constructor(
    private readonly src: string,
    private readonly alt: string,
    /** Percentage of the measure (LaTeX `width=0.5\textwidth` → 50). */
    private readonly widthPct?: number,
  ) {
    super();
  }

  eq(other: ImageWidget): boolean {
    return other.src === this.src && other.alt === this.alt && other.widthPct === this.widthPct;
  }

  toDOM(view: EditorView): HTMLElement {
    const wrap = document.createElement('span');
    wrap.className = 'cm-live-image';

    const img = document.createElement('img');
    img.alt = this.alt;
    if (this.widthPct !== undefined) img.style.width = `${this.widthPct}%`;
    img.addEventListener('load', () => view.requestMeasure());

    const showMissing = (): void => {
      wrap.classList.add('cm-live-image-missing');
      wrap.textContent = `Missing image: ${this.alt || this.src}`;
    };
    img.addEventListener('error', showMissing);

    if (/^(https?:|data:)/i.test(this.src)) {
      img.src = this.src;
    } else {
      view.state
        .facet(assetResolverFacet)(this.src)
        .then((url) => (url ? (img.src = url) : showMissing()))
        .catch(showMissing);
    }

    wrap.appendChild(img);
    return wrap;
  }

  ignoreEvent(): boolean {
    return false;
  }
}
