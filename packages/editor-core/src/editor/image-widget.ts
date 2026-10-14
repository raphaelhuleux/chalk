import { EditorView, WidgetType } from '@codemirror/view';
import { assetResolverFacet } from './asset-resolver';

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
