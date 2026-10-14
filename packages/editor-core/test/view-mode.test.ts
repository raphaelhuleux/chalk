import { describe, it, expect } from 'vitest';
import { mockPort } from './helpers/views';
import {
  sanitizeEditorConfig,
  defaultEditorConfig,
  nextViewMode,
  VIEW_MODES,
} from '../src/editor/theme';
import { EditorView } from '@codemirror/view';
import { mountEditor } from '../src/index';
import { applyViewMode, cycleViewMode, viewModeOf } from '../src/editor/view-mode';
import { __resetMathBuildCount, __mathBuildCount } from '../src/editor/tex-math';

/**
 * The view mode axis: Preview (today's live preview), Mixed (syntax visible
 * and styled, replaced-whole constructs rendered), Source (nothing rendered).
 * Hosts send the DEFAULT through `editor-config.viewMode`; Cmd+: cycles one
 * editor through the three in this order.
 */
describe('viewMode config field', () => {
  it('defaults to preview', () => {
    expect(defaultEditorConfig.viewMode).toBe('preview');
    expect(sanitizeEditorConfig({}).viewMode).toBe('preview');
  });

  it('accepts the three wire values', () => {
    for (const mode of ['preview', 'mixed', 'source'] as const) {
      expect(sanitizeEditorConfig({ viewMode: mode }).viewMode).toBe(mode);
    }
  });

  it('falls back to preview on an unknown value', () => {
    expect(sanitizeEditorConfig({ viewMode: 'raw' }).viewMode).toBe('preview');
    expect(sanitizeEditorConfig({ viewMode: 3 }).viewMode).toBe('preview');
  });

  it('cycles preview → mixed → source → preview', () => {
    expect(VIEW_MODES).toEqual(['preview', 'mixed', 'source']);
    expect(nextViewMode('preview')).toBe('mixed');
    expect(nextViewMode('mixed')).toBe('source');
    expect(nextViewMode('source')).toBe('preview');
  });
});

function mountWith(text: string, language: 'md' | 'tex', viewMode?: string) {
  document.body.innerHTML = '';
  const root = document.createElement('div');
  document.body.appendChild(root);
  const mock = mockPort();
  const editor = mountEditor({ root, port: mock.port });
  mock.push({
    type: 'init',
    text,
    language,
    editorConfig: viewMode ? { viewMode } : undefined,
  });
  const view = EditorView.findFromDOM(root)!;
  const content = () => root.querySelector('.cm-content')!.textContent ?? '';
  // Caret at the end so nothing is selection-revealed.
  view.dispatch({ selection: { anchor: view.state.doc.length } });
  return { editor, view, content, push: mock.push };
}

describe('per-editor view mode', () => {
  const TEX = 'a \\emph{word} b\ntail';

  it('seeds from the config default', () => {
    const { view } = mountWith(TEX, 'tex', 'mixed');
    expect(viewModeOf(view.state)).toBe('mixed');
    const { view: dflt } = mountWith(TEX, 'tex');
    expect(viewModeOf(dflt.state)).toBe('preview');
  });

  it('preview conceals, mixed shows the command, source shows the command', () => {
    const preview = mountWith(TEX, 'tex', 'preview');
    expect(preview.content()).not.toContain('\\emph{');
    const mixed = mountWith(TEX, 'tex', 'mixed');
    expect(mixed.content()).toContain('\\emph{word}');
    const source = mountWith(TEX, 'tex', 'source');
    expect(source.content()).toContain('\\emph{word}');
  });

  it('Cmd+: cycles this editor preview → mixed → source → preview', () => {
    const { view } = mountWith(TEX, 'tex');
    expect(viewModeOf(view.state)).toBe('preview');
    cycleViewMode(view);
    expect(viewModeOf(view.state)).toBe('mixed');
    cycleViewMode(view);
    expect(viewModeOf(view.state)).toBe('source');
    cycleViewMode(view);
    expect(viewModeOf(view.state)).toBe('preview');
  });

  it('applyViewMode reconfigures the live editor', () => {
    const { view, content } = mountWith(TEX, 'tex');
    applyViewMode(view, 'source');
    expect(viewModeOf(view.state)).toBe('source');
    expect(content()).toContain('\\emph{word}');
    applyViewMode(view, 'preview');
    expect(content()).not.toContain('\\emph{');
  });

  it('a changed default resets the editor; an unchanged default leaves a cycled editor alone', () => {
    const { view, push } = mountWith(TEX, 'tex', 'preview');
    cycleViewMode(view); // user flipped this editor to mixed
    expect(viewModeOf(view.state)).toBe('mixed');
    // The host re-sends its config for an unrelated field: the default is
    // still preview, so the editor keeps the user's choice.
    push({ type: 'editor-config', config: { viewMode: 'preview', editingMode: 'focus' } });
    expect(viewModeOf(view.state)).toBe('mixed');
    // The default itself changes: every editor follows it.
    push({ type: 'editor-config', config: { viewMode: 'source' } });
    expect(viewModeOf(view.state)).toBe('source');
  });

  it('a config without viewMode (an older host) counts as preview and never resets', () => {
    const { view, push } = mountWith(TEX, 'tex');
    cycleViewMode(view);
    push({ type: 'editor-config', config: { editingMode: 'zen' } });
    expect(viewModeOf(view.state)).toBe('mixed');
  });
});

describe('switching Preview and Mixed keeps the rendered math', () => {
  // Both sets render math the same way, so they share one field instance: a
  // switch must not rebuild (and re-typeset) every equation in the document.
  for (const language of ['tex', 'md'] as const) {
    it(`${language}: no math rebuild on Preview → Mixed → Preview`, () => {
      const { view } = mountWith('Inline $a+b$ here.\n\n$$\nx^2\n$$\n\ntail', language);
      __resetMathBuildCount();
      cycleViewMode(view); // → mixed
      expect(viewModeOf(view.state)).toBe('mixed');
      applyViewMode(view, 'preview');
      expect(__mathBuildCount()).toBe(0);
      view.destroy();
    });
  }
});
