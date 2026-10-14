import { EditorState, Extension, Facet, StateEffect, StateField } from '@codemirror/state';
import { EditorView, keymap, type Command } from '@codemirror/view';
import { nextViewMode, previewCompartment, type ViewMode } from './theme';

// Per-editor view mode (preview / mixed / source). The host sends only the
// DEFAULT in `editor-config.viewMode`; mount.ts resets this editor only when
// that default changes, so Cmd+: on one tab survives other config pushes.
//
// Each language hands over three preview-compartment sets. Mixed is the SAME
// builders called with `{ conceal: false }` (hides become `cm-syntax-dim`):
// don't add a second builder for it, and don't make Mixed hide anything but
// math, images and tables.

export const setViewMode = StateEffect.define<ViewMode>();

const viewModeField = StateField.define<ViewMode>({
  create: () => 'preview',
  update(value, tr) {
    for (const e of tr.effects) if (e.is(setViewMode)) value = e.value;
    return value;
  },
});

/** The editor's current mode; `preview` on a state without the field. */
export function viewModeOf(state: EditorState): ViewMode {
  return state.field(viewModeField, false) ?? 'preview';
}

/** Source: nothing hidden, every motion is CodeMirror's default. */
export function isSourceMode(state: EditorState): boolean {
  return viewModeOf(state) === 'source';
}

/** Preview: fences collapse, so the fence-stop keymaps have a row to stop on. */
export function isPreviewMode(state: EditorState): boolean {
  return viewModeOf(state) === 'preview';
}

export type PreviewSets = Record<ViewMode, Extension>;

const previewSetsFacet = Facet.define<PreviewSets, PreviewSets | null>({
  combine: (values) => values[0] ?? null,
});

/** Switch one editor to `mode`. False when the editor carries no preview sets
 *  (a bare state in a unit test). */
export function applyViewMode(view: EditorView, mode: ViewMode): boolean {
  const sets = view.state.facet(previewSetsFacet);
  if (!sets) return false;
  if (viewModeOf(view.state) === mode) return true;
  view.dispatch({
    effects: [setViewMode.of(mode), previewCompartment.reconfigure(sets[mode])],
  });
  return true;
}

/** Cmd+: cycles preview, mixed, source. */
export const cycleViewMode: Command = (view) =>
  applyViewMode(view, nextViewMode(viewModeOf(view.state)));

/** View-mode state seeded with the host default, plus the Cmd+: key. Use in
 *  place of `previewCompartment.of(...)`. */
export function viewModeExtension(sets: PreviewSets, initial: ViewMode): Extension {
  return [
    viewModeField.init(() => initial),
    previewSetsFacet.of(sets),
    previewCompartment.of(sets[initial]),
    keymap.of([{ key: 'Mod-:', run: cycleViewMode }]),
  ];
}
