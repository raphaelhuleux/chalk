import { EditorState, Extension } from '@codemirror/state';
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
  syntaxHighlighting,
} from '@codemirror/language';
import {
  acceptCompletion,
  closeBrackets,
  closeBracketsKeymap,
} from '@codemirror/autocomplete';
import {
  searchKeymap,
  highlightSelectionMatches,
} from '@codemirror/search';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { markdown } from '@codemirror/lang-markdown';
import { Strikethrough, TaskList } from '@lezer/markdown';

import { themeCompartment, previewCompartment, vsCodeTheme } from './theme';
import { chalkKeymap, EditorActions } from './keymap';
import { hsnipsExtension, hsnipsKeymap } from './hsnips-plugin';

import { texMathPlugin, isInMathContextTex } from './tex-math';
import { texHighlightStyle } from './tex-syntax-highlight';
import { latexCompletionExtension } from './latex-completions';

import { mathPlugin, mathSyntax, isInMathContextMd } from './md-math-plugin';
import { livePreviewPlugin } from './md-live-preview';

export type Language = 'tex' | 'md';

export function buildExtensions(
  actions: EditorActions,
  language: Language,
): Extension[] {
  const shared = [
    keymap.of(hsnipsKeymap),
    keymap.of([{ key: 'Tab', run: acceptCompletion }]),
    keymap.of(chalkKeymap()),

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
    EditorView.lineWrapping,

    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        actions.onContentChange(update.state.doc.toString());
      }
    }),

    themeCompartment.of(vsCodeTheme()),
  ];

  if (language === 'tex') {
    return [
      ...shared,
      StreamLanguage.define(stex),
      syntaxHighlighting(texHighlightStyle),
      texMathPlugin(),
      hsnipsExtension({ isInMathContext: isInMathContextTex }),
      latexCompletionExtension(),
      placeholder('% Start typing LaTeX…'),
    ];
  }

  // language === 'md' — note: no latexCompletionExtension; markdown
  // doesn't get LaTeX env/command autocomplete.
  return [
    ...shared,
    markdown({ extensions: [mathSyntax, Strikethrough, TaskList] }),
    previewCompartment.of([mathPlugin(), livePreviewPlugin()]),
    hsnipsExtension({ isInMathContext: isInMathContextMd }),
    placeholder('Start typing…'),
  ];
}

export function createEditorState(
  content: string,
  actions: EditorActions,
  language: Language,
): EditorState {
  return EditorState.create({
    doc: content,
    extensions: buildExtensions(actions, language),
  });
}

export function createEditor(
  parent: HTMLElement,
  content: string,
  actions: EditorActions,
  language: Language,
): EditorView {
  const state = createEditorState(content, actions, language);
  const view = new EditorView({ state, parent });
  view.focus();
  return view;
}
