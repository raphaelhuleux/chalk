import { EditorView } from '@codemirror/view';
import { Transaction } from '@codemirror/state';
import { createEditor, type EditorActions, type Language } from './editor/setup';
import { setVsCodeApi, sendEdit, sendReady } from './api';
import { parseHSnips } from './editor/hsnips-parser';
import { setSnippets } from './editor/hsnips-plugin';

// KaTeX's CSS needs to be bundled. Importing it from the entry point causes
// esbuild to emit dist/webview.css alongside dist/webview.js.
import 'katex/dist/katex.min.css';
import './styles/editor.css';
import './styles/math.css';

interface VsCodeApi {
  postMessage(msg: unknown): void;
  getState(): unknown;
  setState(state: unknown): void;
}
declare function acquireVsCodeApi(): VsCodeApi;

const vscodeApi = acquireVsCodeApi();
setVsCodeApi(vscodeApi);

let view: EditorView | null = null;
let lastKnownText = '';

const actions: EditorActions = {
  onContentChange: (content: string) => {
    if (content === lastKnownText) return;
    lastKnownText = content;
    sendEdit(content);
  },
};

type ThemeColors = Partial<{
  keyword: string | null;
  tagName: string | null;
  comment: string | null;
  number: string | null;
  atom: string | null;
  bracket: string | null;
  specialVariable: string | null;
  invalid: string | null;
}>;

type HeadingColors = Partial<Record<1 | 2 | 3 | 4 | 5 | 6, string>>;

type ExtensionMessage =
  | { type: 'init'; text: string; language: Language }
  | { type: 'update'; text: string }
  | { type: 'theme-colors'; colors: ThemeColors }
  | { type: 'heading-colors'; colors: HeadingColors }
  | { type: 'hsnips'; content: string };

/**
 * Inject theme colors as CSS custom properties on <html>. Our
 * HighlightStyle references `var(--chalk-syntax-*, <fallback>)`, so
 * when a property is set the themed color takes over; when it's unset
 * (theme read failed, field null) the baked-in hex fallback applies.
 */
function applyThemeColors(colors: ThemeColors): void {
  const root = document.documentElement;
  const set = (key: string, value: string | null | undefined): void => {
    if (value) root.style.setProperty(key, value);
    else root.style.removeProperty(key);
  };
  set('--chalk-syntax-keyword', colors.keyword);
  set('--chalk-syntax-tag', colors.tagName);
  set('--chalk-syntax-comment', colors.comment);
  set('--chalk-syntax-number', colors.number);
  set('--chalk-syntax-atom', colors.atom);
  set('--chalk-syntax-bracket', colors.bracket);
  set('--chalk-syntax-special-variable', colors.specialVariable);
  set('--chalk-syntax-invalid', colors.invalid);
}

function handleMessage(msg: ExtensionMessage): void {
  switch (msg.type) {
    case 'init': {
      lastKnownText = msg.text;
      const root = document.getElementById('editor-root');
      if (!root) {
        console.error('#editor-root not found');
        return;
      }
      if (view) {
        view.destroy();
        view = null;
      }
      view = createEditor(root, msg.text, actions, msg.language);
      return;
    }
    case 'update': {
      if (!view) return;
      if (msg.text === view.state.doc.toString()) return;
      lastKnownText = msg.text;
      view.dispatch({
        changes: {
          from: 0,
          to: view.state.doc.length,
          insert: msg.text,
        },
        // Sync-back from extension host — don't pollute undo history.
        annotations: [Transaction.addToHistory.of(false)],
      });
      return;
    }
    case 'theme-colors': {
      applyThemeColors(msg.colors);
      return;
    }
    case 'heading-colors': {
      const root = document.documentElement;
      for (const level of [1, 2, 3, 4, 5, 6] as const) {
        const c = msg.colors[level];
        if (c) root.style.setProperty(`--chalk-heading-${level}`, c);
        else root.style.removeProperty(`--chalk-heading-${level}`);
      }
      return;
    }
    case 'hsnips': {
      if (!view) return;
      const snippets = parseHSnips(msg.content);
      view.dispatch({
        effects: [setSnippets.of(snippets)],
      });
      return;
    }
  }
}

window.addEventListener('message', (e: MessageEvent) => {
  handleMessage(e.data as ExtensionMessage);
});

sendReady();
