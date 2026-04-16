import { EditorView } from '@codemirror/view';
import { createEditor } from './editor/setup';
import type { EditorActions } from './editor/keymap';
import { setVsCodeApi, sendEdit, sendReady } from './api';

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

type ExtensionMessage =
  | { type: 'init'; text: string }
  | { type: 'update'; text: string };

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
      view = createEditor(root, msg.text, actions);
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
      });
      return;
    }
  }
}

window.addEventListener('message', (e: MessageEvent) => {
  handleMessage(e.data as ExtensionMessage);
});

sendReady();
