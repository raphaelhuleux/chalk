import { WidgetType } from '@codemirror/view';
import { EditorState, Extension } from '@codemirror/state';
import { KaTeXCache } from '../utils/katex-cache';
import { calloutBlockAt, calloutTagClasses, sameCalloutTag, type CalloutTag } from './callout-core';
import {
  displayMathArrows,
  displayMathField,
  regionAt,
} from './display-math-core';
import { frameBlockAt } from './tex-frame-plugin';
import { scanTexCallouts } from './tex-callout-plugin';
import { listFenceHideThrough, scanTexLists, texListLineDepths } from './tex-list-plugin';
import { listHangEm } from './hanging-indent';
import { mathRegionsOf, type MathRegion } from './tex-math-incremental';

/**
 * The scanner and `mathRegionsField` live in tex-math-incremental.ts; this file
 * is the widget and plugin on top. Re-exported for callers that already
 * import this module.
 */
export {
  mathRegionsField,
  mathRegionsOf,
  scanMathRegions,
  __scanCount,
  __resetScanCount,
  type MathRegion,
} from './tex-math-incremental';

class MathWidget extends WidgetType {
  constructor(
    private readonly content: string,
    private readonly display: boolean,
    private readonly cache: KaTeXCache,
    // Callout / beamer-frame box to continue: see texSettled.
    private readonly callout: CalloutTag | null = null,
    private readonly frame: boolean = false,
    // Equation numbers emitted by all preceding regions. KaTeX's counter is
    // DOM-order and CM6 only keeps visible widgets, so without this the first
    // equation on screen is always (1). See countSourceEquationNumbers.
    private readonly eqOffset: number = 0,
    // Display math inside a list item: the item's text indent, in em, so the
    // formula centres in the item's column (tex-list-plugin's layout).
    private readonly listHang: number = 0,
  ) {
    super();
  }

  eq(other: MathWidget): boolean {
    return (
      this.content === other.content &&
      this.display === other.display &&
      sameCalloutTag(this.callout, other.callout) &&
      this.frame === other.frame &&
      this.eqOffset === other.eqOffset &&
      this.listHang === other.listHang
    );
  }

  toDOM(): HTMLElement {
    const host = document.createElement(this.display ? 'div' : 'span');
    const cls = [this.display ? 'cm-tex-math-display' : 'cm-tex-math-inline'];
    cls.push(...calloutTagClasses(this.callout));
    if (this.frame) cls.push('cm-slide');
    host.className = cls.join(' ');
    if (this.display) {
      host.style.setProperty('--chalk-eq-offset', String(this.eqOffset));
    }
    const html = this.cache.render(this.content, this.display);
    if (html === null) {
      // Parse error: show the raw source so the user can fix it.
      host.textContent = this.content;
      host.classList.add('cm-tex-math-error');
    } else if (this.listHang > 0) {
      // An inner box, not padding on the host: the host carries the callout
      // or slide card's own padding and edges.
      const indent = document.createElement('div');
      indent.className = 'cm-tex-math-list-indent';
      indent.style.paddingLeft = `${this.listHang}em`;
      indent.innerHTML = html;
      host.appendChild(indent);
    } else {
      host.innerHTML = html;
    }
    return host;
  }

  ignoreEvent(): boolean {
    // Let clicks reach CM6 so they place the caret and reveal the source.
    return false;
  }
}
/** Rebuild counter of the shared math field, re-exported for tests. */
export { __mathBuildCount, __resetMathBuildCount } from './display-math-core';

/**
 * The rendered widget for a region the caret is not in, plus how far the
 * replace reaches. A display block inside a callout or a beamer frame gets
 * tagged so the widget continues the box: a block-replace widget is not a
 * `.cm-line`, so the per-line background / edges cannot reach it.
 */
function texSettled(
  cache: KaTeXCache,
  state: EditorState,
  r: MathRegion,
  eqOffset: number,
): { widget: WidgetType; hideTo?: number } {
  // scanTexCallouts is Text-identity cached, so this is O(regions). As the box
  // bottom, the replace extends through the collapsed fence line (`hideTo`).
  const callout = r.display
    ? calloutBlockAt(state.doc, scanTexCallouts, r.from, r.to, state.selection.main)
    : null;
  // Frame cards need side edges only: the `\end{frame}` row is always the foot.
  const frame = r.display ? frameBlockAt(state.doc, r.from, r.to) : false;
  // A display block directly above a collapsed `\end{enumerate}`/`\end{itemize}`
  // absorbs those fence lines too (listFenceHideThrough). Not when a collapsed
  // callout close fence follows: its merge host would fall inside this replace
  // and leave a phantom row, so that rare stack keeps the list fence revealed.
  let hideTo = callout?.hideTo;
  if (r.display && hideTo == null) {
    const listTo = listFenceHideThrough(state.doc, r.from, r.to, state.selection.main);
    if (listTo != null) {
      const nextLine = state.doc.lineAt(listTo).number + 1;
      const calloutCloseFollows =
        nextLine <= state.doc.lines &&
        scanTexCallouts(state.doc).some((c) => c.closeLine === nextLine);
      if (!calloutCloseFollows) hideTo = listTo;
    }
  }
  const listDepth = r.display
    ? (texListLineDepths(state.doc).get(state.doc.lineAt(r.from).number) ?? 0)
    : 0;
  return {
    widget: new MathWidget(r.content, r.display, cache, callout, frame, eqOffset, listHangEm(listDepth)),
    hideTo,
  };
}

export function texMathPlugin(): Extension {
  // One KaTeX cache per editor instance.
  const cache = new KaTeXCache();
  return displayMathField<MathRegion>({
    regionsOf: mathRegionsOf,
    settled: (state, r, eqOffset) => texSettled(cache, state, r, eqOffset),
    preview: {
      cache,
      className: 'cm-tex-math-preview',
      scanCallouts: scanTexCallouts,
    },
    widgetSelector: '.cm-tex-math-inline, .cm-tex-math-display',
    // A display block's replace starts at the whole-line boundary, which can
    // sit before the region's own `from`; the caret belongs at `from`.
    clickSnapsToRegionStart: true,
    // A display block directly above a collapsed list fence absorbs it
    // (texSettled), and that collapse reads the selection.
    fenceNearCaret(doc, nearLine) {
      return scanTexLists(doc).some((l) => nearLine(l.openLine) || nearLine(l.closeLine));
    },
  });
}

/**
 * True when `pos` lies in a math region; the hsnips `math(context)` gate.
 * Reads the cached field, or scans directly when it isn't installed (tests).
 */
export function isInMathContextTex(state: EditorState, pos: number): boolean {
  return regionAt(mathRegionsOf(state), pos) !== null;
}

// Up/Down into collapsed display math: shared with md (displayMathArrows).
const texArrows = displayMathArrows(mathRegionsOf);

export const texMathArrowKeymap: Extension = texArrows.extension;

// Exported for tests.
export const _testing = {
  enterDisplayMathFromAbove: texArrows.fromAbove,
  enterDisplayMathFromBelow: texArrows.fromBelow,
};
