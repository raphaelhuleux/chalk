import { EditorState } from '@codemirror/state';
import {
  EditorView,
  keymap,
  placeholder,
  drawSelection,
  highlightSpecialChars,
  lineNumbers,
} from '@codemirror/view';
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from '@codemirror/commands';
import {
  bracketMatching,
  indentUnit,
  StreamLanguage,
} from '@codemirror/language';
import {
  closeBrackets,
  closeBracketsKeymap,
} from '@codemirror/autocomplete';
import {
  searchKeymap,
  highlightSelectionMatches,
} from '@codemirror/search';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { themeCompartment, vsCodeTheme } from './theme';
import { chalkKeymap, EditorActions } from './keymap';
import { texMathPlugin } from './tex-math';

/**
 * Builds the full extensions array for a CM6 editor instance.
 *
 * vs. chalk-md:
 *   - `stex` stream language replaces `markdown(…)` for syntax highlighting
 *   - `texMathPlugin()` replaces `mathPlugin()` + `livePreviewPlugin()`
 *     (there is no live-preview for prose; only math widgets)
 *   - no `previewCompartment` wrapper (math is always on; use VS Code's
 *     "Reopen With → Text Editor" if you want raw LaTeX)
 */
export function buildExtensions(actions: EditorActions) {
  return [
    keymap.of(chalkKeymap(actions)),

    keymap.of([indentWithTab]),
    keymap.of(closeBracketsKeymap),
    keymap.of(historyKeymap),
    keymap.of(searchKeymap),
    keymap.of(defaultKeymap),

    lineNumbers(),
    history(),
    bracketMatching(),
    closeBrackets(),
    drawSelection(),
    highlightSpecialChars(),
    highlightSelectionMatches(),

    indentUnit.of('    '),

    // LaTeX syntax highlighting via CM6's legacy-modes stream language.
    StreamLanguage.define(stex),

    // Live math preview.
    texMathPlugin(),

    EditorView.lineWrapping,

    placeholder('% Start typing LaTeX…'),

    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        actions.onContentChange(update.state.doc.toString());
      }
    }),

    themeCompartment.of(vsCodeTheme()),
  ];
}

export function createEditorState(
  content: string,
  actions: EditorActions,
): EditorState {
  return EditorState.create({
    doc: content,
    extensions: buildExtensions(actions),
  });
}

export function createEditor(
  parent: HTMLElement,
  content: string,
  actions: EditorActions,
): EditorView {
  const state = createEditorState(content, actions);
  const view = new EditorView({ state, parent });
  view.focus();
  return view;
}
