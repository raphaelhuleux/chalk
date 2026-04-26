import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view';
import { Extension, RangeSetBuilder } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import '../styles/editor.css';
import { openExternal } from '../api';

// ---------------------------------------------------------------------------
//  Widgets
// ---------------------------------------------------------------------------

class HRWidget extends WidgetType {
  toDOM(): HTMLElement {
    const hr = document.createElement('hr');
    hr.className = 'cm-live-hr';
    return hr;
  }

  eq(): boolean {
    return true; // all HRs are identical
  }

  ignoreEvent(): boolean {
    return false;
  }
}

// ---------------------------------------------------------------------------
//  Build live-preview decorations from the syntax tree
// ---------------------------------------------------------------------------

function buildLivePreviewDecorations(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { state } = view;
  const cursor = state.selection.main;
  const tree = syntaxTree(state);

  for (const { from, to } of view.visibleRanges) {
    tree.iterate({
      from,
      to,
      enter(node) {
        // Skip math nodes — handled by math-plugin.ts
        if (
          node.name === 'InlineMath' ||
          node.name === 'DisplayMath'
        ) {
          return false; // don't descend into children
        }

        // ---- Headings (ATXHeading1–ATXHeading6) ----
        // Bold + colored. The `#` marks stay visible (VS Code convention —
        // writers editing markdown in VS Code expect to see syntax).
        const headingMatch = node.name.match(/^ATXHeading(\d)$/);
        if (headingMatch) {
          const level = parseInt(headingMatch[1]);
          builder.add(node.from, node.to, Decoration.mark({ class: `cm-h${level}` }));
          return false;
        }

        // ---- StrongEmphasis (bold / bold-italic) ----
        if (node.name === 'StrongEmphasis') {
          const emphFrom = node.from;
          const emphTo = node.to;

          // Inline cursor check: cursor on opening delimiter = inside, past closing = outside
          const cursorInside = cursor.head >= emphFrom && cursor.head < emphTo;
          if (cursorInside) {
            return false; // show raw text when cursor is inside
          }

          // Collect EmphasisMark children and check for nested Emphasis
          const marks: Array<{ from: number; to: number }> = [];
          let hasNestedEmphasis = false;
          let child = node.node.firstChild;
          while (child) {
            if (child.name === 'EmphasisMark') {
              marks.push({ from: child.from, to: child.to });
            }
            if (child.name === 'Emphasis') {
              hasNestedEmphasis = true;
            }
            child = child.nextSibling;
          }

          const className = hasNestedEmphasis ? 'cm-live-bold-italic' : 'cm-live-bold';

          if (marks.length >= 2) {
            const opening = marks[0];
            const closing = marks[marks.length - 1];
            builder.add(opening.from, opening.to, Decoration.replace({}));
            builder.add(opening.to, closing.from, Decoration.mark({ class: className }));
            builder.add(closing.from, closing.to, Decoration.replace({}));
          }

          return false; // don't descend into children
        }

        // ---- Emphasis (italic) ----
        if (node.name === 'Emphasis') {
          const emphFrom = node.from;
          const emphTo = node.to;

          // Inline cursor check: cursor on opening delimiter = inside, past closing = outside
          const cursorInside = cursor.head >= emphFrom && cursor.head < emphTo;
          if (cursorInside) {
            return false; // show raw text when cursor is inside
          }

          // Collect EmphasisMark children
          const marks: Array<{ from: number; to: number }> = [];
          let child = node.node.firstChild;
          while (child) {
            if (child.name === 'EmphasisMark') {
              marks.push({ from: child.from, to: child.to });
            }
            child = child.nextSibling;
          }

          if (marks.length >= 2) {
            const opening = marks[0];
            const closing = marks[marks.length - 1];
            builder.add(opening.from, opening.to, Decoration.replace({}));
            builder.add(opening.to, closing.from, Decoration.mark({ class: 'cm-live-italic' }));
            builder.add(closing.from, closing.to, Decoration.replace({}));
          }

          return false; // don't descend into children
        }

        // ---- Strikethrough ----
        if (node.name === 'Strikethrough') {
          const cursorInside = cursor.head >= node.from && cursor.head < node.to;
          if (cursorInside) return false;

          const marks: Array<{ from: number; to: number }> = [];
          let child = node.node.firstChild;
          while (child) {
            if (child.name === 'StrikethroughMark') marks.push({ from: child.from, to: child.to });
            child = child.nextSibling;
          }

          if (marks.length >= 2) {
            const opening = marks[0];
            const closing = marks[marks.length - 1];
            builder.add(opening.from, opening.to, Decoration.replace({}));
            builder.add(opening.to, closing.from, Decoration.mark({ class: 'cm-live-strikethrough' }));
            builder.add(closing.from, closing.to, Decoration.replace({}));
          }

          return false;
        }

        // ---- Inline Code ----
        if (node.name === 'InlineCode') {
          const cursorInside = cursor.head >= node.from && cursor.head < node.to;
          if (cursorInside) return false;

          const marks: Array<{ from: number; to: number }> = [];
          let child = node.node.firstChild;
          while (child) {
            if (child.name === 'CodeMark') marks.push({ from: child.from, to: child.to });
            child = child.nextSibling;
          }

          if (marks.length >= 2) {
            const opening = marks[0];
            const closing = marks[marks.length - 1];
            builder.add(opening.from, opening.to, Decoration.replace({}));
            builder.add(opening.to, closing.from, Decoration.mark({ class: 'cm-live-code' }));
            builder.add(closing.from, closing.to, Decoration.replace({}));
          }

          return false;
        }

        // ---- Links ----
        if (node.name === 'Link') {
          const cursorInside = cursor.head >= node.from && cursor.head < node.to;
          if (cursorInside) return false;

          const n = node.node;
          const urlNode = n.getChild('URL');
          const urlStr = urlNode ? state.doc.sliceString(urlNode.from, urlNode.to) : '';

          // Collect all LinkMark children
          const linkMarks: Array<{ from: number; to: number }> = [];
          let child = n.firstChild;
          while (child) {
            if (child.name === 'LinkMark') linkMarks.push({ from: child.from, to: child.to });
            child = child.nextSibling;
          }

          // We need at least [ and ] marks
          if (linkMarks.length >= 2) {
            const openBracket = linkMarks[0]; // [
            const closeBracket = linkMarks[1]; // ]

            // Hide [
            builder.add(openBracket.from, openBracket.to, Decoration.replace({}));
            // Style the link text between [ and ]
            builder.add(
              openBracket.to,
              closeBracket.from,
              Decoration.mark({
                class: 'cm-live-link',
                attributes: { 'data-url': urlStr },
              }),
            );
            // Hide ](url) — everything from ] to end of Link node
            builder.add(closeBracket.from, node.to, Decoration.replace({}));
          }

          return false;
        }

        // ---- Blockquote ----
        if (node.name === 'Blockquote') {
          // Apply blockquote styling to entire block — but DON'T return false
          // because we need children (QuoteMark, and inline elements inside) to be processed too
          builder.add(node.from, node.to, Decoration.mark({ class: 'cm-live-blockquote' }));
          // Let tree iteration continue into children
        }

        // ---- QuoteMark (the > character) ----
        if (node.name === 'QuoteMark') {
          const line = state.doc.lineAt(node.from);
          const cursorLine = state.doc.lineAt(cursor.head);
          const cursorOnLine = cursorLine.number === line.number;

          if (!cursorOnLine) {
            builder.add(node.from, node.to, Decoration.mark({ class: 'cm-live-quote-mark' }));
          }
        }

        // ---- List markers (- / * / + and 1. / 2. / …) ----
        // Both BulletList and OrderedList produce a ListMark child for the
        // marker itself. We mark (not replace) it: structural punctuation
        // stays visible at all times, like the # in a heading. Don't
        // return — children inside list items still need processing.
        if (node.name === 'ListMark') {
          builder.add(node.from, node.to, Decoration.mark({ class: 'cm-live-list-mark' }));
        }

        // ---- Horizontal Rule ----
        if (node.name === 'HorizontalRule') {
          const line = state.doc.lineAt(node.from);
          const cursorLine = state.doc.lineAt(cursor.head);
          const cursorOnLine = cursorLine.number === line.number;

          if (!cursorOnLine) {
            builder.add(node.from, node.to, Decoration.replace({ widget: new HRWidget() }));
          }

          return false;
        }
      },
    });
  }

  return builder.finish();
}

// ---------------------------------------------------------------------------
//  ViewPlugin
// ---------------------------------------------------------------------------

const livePreviewViewPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    constructor(view: EditorView) {
      this.decorations = buildLivePreviewDecorations(view);
    }

    update(update: ViewUpdate) {
      if (
        update.docChanged ||
        update.selectionSet ||
        update.viewportChanged ||
        syntaxTree(update.state) !== syntaxTree(update.startState)
      ) {
        this.decorations = buildLivePreviewDecorations(update.view);
      }
    }
  },
  { decorations: (v) => v.decorations },
);

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export function livePreviewPlugin(): Extension {
  return [
    livePreviewViewPlugin,
    EditorView.domEventHandlers({
      click(event: MouseEvent, view: EditorView) {
        const target = event.target as HTMLElement;

        // Cmd+click on links
        if (!event.metaKey && !event.ctrlKey) return false;
        const linkEl = target.closest('.cm-live-link');
        if (!linkEl) return false;
        const url = linkEl.getAttribute('data-url');
        if (url) {
          openExternal(url);
          return true;
        }
        return false;
      },
    }),
  ];
}
