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
import { hsnipsExtension, hsnipsKeymap } from './hsnips-plugin';

import { texMathPlugin, isInMathContextTex, texMathArrowKeymap } from './tex-math';
import { taboutKeymap } from './tabout';
import { texHighlightStyle } from './tex-syntax-highlight';
import { latexCompletionExtension } from './latex-completions';

import { mathPlugin, mathSyntax, isInMathContextMd, mdMathArrowKeymap } from './md-math-plugin';
import { livePreviewPlugin } from './md-live-preview';

export type Language = 'tex' | 'md';

/** Callbacks the webview bootstrap supplies to the editor. The only
 *  channel into the host is content-change notification; everything
 *  else (save, reopen, etc.) is owned by VS Code. */
export interface EditorActions {
  onContentChange: (content: string) => void;
}

export function buildExtensions(
  actions: EditorActions,
  language: Language,
): Extension[] {
  const shared = [
    keymap.of(hsnipsKeymap),
    keymap.of([{ key: 'Tab', run: acceptCompletion }]),

    // indentWithTab is wired per-language AFTER taboutKeymap so Tabout
    // (math-context-only) gets first crack at Tab before falling through
    // to indent.
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
      texMathArrowKeymap,
      hsnipsExtension({ isInMathContext: isInMathContextTex }),
      latexCompletionExtension(),
      taboutKeymap(isInMathContextTex, 'tex'),
      keymap.of([indentWithTab]),
      placeholder('% Start typing LaTeX…'),
    ];
  }

  // language === 'md' — note: no latexCompletionExtension; markdown
  // doesn't get LaTeX env/command autocomplete.
  return [
    ...shared,
    markdown({ extensions: [mathSyntax, Strikethrough, TaskList] }),
    previewCompartment.of([mathPlugin(), livePreviewPlugin()]),
    mdMathArrowKeymap,
    hsnipsExtension({ isInMathContext: isInMathContextMd }),
    taboutKeymap(isInMathContextMd, 'md'),
    keymap.of([indentWithTab]),
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
