/**
 * @chalk/editor-core: the host-agnostic Chalk editor. Each host implements a
 * `HostPort` (the only contract) and calls `mountEditor`, whose imports pull in
 * the CSS. Default snippets sit behind `@chalk/editor-core/default-hsnips` so
 * they stay out of the editor bundle; so does mermaid, which each host builds
 * from `@chalk/editor-core/mermaid-entry` into a script of its own.
 */
export { mountEditor } from './mount';
export type { MountOptions, MountedEditor, OutlineSnapshot } from './mount';
export type {
  HostPort,
  HostToEditorMessage,
  EditorToHostMessage,
  ThemeColors,
  HeadingColors,
} from './host-port';
export { createRequestChannel, requestHooks, REPLY_FIELDS } from './host-request';
export type { RequestChannel } from './host-request';
export type { Language, EditorActions } from './editor/setup';
export type { OutlineItem } from './editor/outline';
export type { EditorConfig, ViewMode } from './editor/theme';
export type { WorkspaceAccess, WorkspaceFileKind } from './editor/workspace-files';
export { scriptMermaidLoader } from './editor/md-mermaid-plugin';
export type { MermaidLoader } from './editor/md-mermaid-plugin';
