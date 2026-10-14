import { EditorState, Extension } from '@codemirror/state';
import {
  EditorView,
  keymap,
  placeholder,
  drawSelection,
  highlightSpecialChars,
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
import { search, searchKeymap } from '@codemirror/search';
import { chalkSearchPanel, toggleSearchPanel } from './search-panel';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { markdown } from '@codemirror/lang-markdown';
import { Strikethrough, TaskList, Table } from '@lezer/markdown';

import {
  themeCompartment,
  vsCodeTheme,
  defaultEditorConfig,
  type EditorConfig,
} from './theme';
import { isSourceMode, viewModeExtension, type PreviewSets } from './view-mode';
import { hsnipsExtension, hsnipsKeymap } from './hsnips-plugin';
import { isInLatexTextSpan } from './latex-text-span';

import { texMathPlugin, mathRegionsField, isInMathContextTex, texMathArrowKeymap } from './tex-math';
import { texImagePlugin } from './tex-image';
import { texConcealPlugin } from './tex-conceal-plugin';
import { texLayoutDimPlugin } from './tex-layout-dim';
import {
  markdownTypesetCompartment,
  markdownTypesetExtension,
  mdTypesetPlugin,
} from './md-typeset';
import { pointerGestureExtension } from './pointer-gesture';
import { texVerticalArrowKeymap } from './tex-vertical-motion';
import { mdVerticalArrowKeymap } from './md-vertical-motion';
import { hangingIndent } from './hanging-indent';
import { editingModeCompartment, editingModeExtension } from './typewriter-mode';
import { taboutKeymap } from './tabout';
import { horizontalNavKeymap } from './horizontal-nav';
import { mathWrapInputHandler } from './math-wrap';
import { itemNewlineKeymap } from './item-newline';
import { texHighlightStyle } from './tex-syntax-highlight';
import { texDecorationsPlugin, texStyleRegionsField } from './tex-decorations';
import { latexCompletionExtension } from './latex-completions';
import { mdCompletionExtension } from './md-completions';
import { comfortableBottom, chromeTopMargin } from './comfortable-scroll';
import { mdFormatKeymap, texFormatKeymap } from './format-shortcuts';
import { texCalloutPlugin, texCalloutFenceKeymap } from './tex-callout-plugin';
import { texFramePlugin, texFrameFenceKeymap } from './tex-frame-plugin';
import { texListPlugin, texListFenceKeymap, texListLineCollapsed } from './tex-list-plugin';
import { deadKeyCommitDedupe } from './dead-key-commit';

import { mathPlugin, mathSyntax, isInMathContextMd, mdMathArrowKeymap } from './md-math-plugin';
import { highlightSyntax } from './md-highlight-plugin';
import { livePreviewPlugin } from './md-live-preview';
import { calloutPlugin, mdCalloutFenceKeymap } from './md-callout-plugin';
import { mdCrossrefPlugin } from './md-crossref-plugin';
import { frontmatterSyntax, frontmatterDimExtension } from './md-frontmatter';
import { mdCodeLanguages } from './code-languages';
import { codeHighlightStyle } from './code-syntax-highlight';
import { codeBlockPlugin } from './md-code-block-plugin';
import { mermaidLoaderFacet, mermaidPlugin, type MermaidLoader } from './md-mermaid-plugin';
import { tablePlugin } from './table-field';
import { mdListNewlineKeymap } from './md-list-newline';
import { mdListIndentKeymap } from './md-list-indent';
import { assetResolverFacet, type AssetResolver } from './asset-resolver';
import { workspaceAccessFacet, type WorkspaceAccess } from './workspace-files';
import { memoizedAssetResolver } from '../utils/asset-cache';
import { docText } from '../utils/doc-text';

/**
 * Snippet `math(context)`: inside math but not inside a `\text{…}` argument,
 * mirroring latex.hsnips' `math()`. Snippets only: tabout, math-wrap and
 * item-newline keep working inside `\text{}`.
 */
function snippetMathContext(
  isInMath: (state: EditorState, pos: number) => boolean,
): (state: EditorState, pos: number) => boolean {
  return (state, pos) => isInMath(state, pos) && !isInLatexTextSpan(state, pos);
}

export type Language = 'tex' | 'md';

/** Host callbacks. Content change is the only one; save and the rest are
 *  owned by the host. */
export interface EditorActions {
  onContentChange: (content: string) => void;
}

/** The optional half of an editor's setup. */
export interface EditorOptions {
  /** Host config; the pre-config defaults when omitted. */
  config?: EditorConfig;
  /** Host image resolver; images don't render without one. */
  resolveAsset?: AssetResolver;
  /** Files around the document, for path and citation completion. */
  workspaceAccess?: WorkspaceAccess;
  /** Loads the mermaid renderer; ```mermaid fences render as code without one. */
  loadMermaid?: MermaidLoader;
  /** Mac Catalyst's dead-key commit dedupe (dead-key-commit.ts). */
  deadKeyDedupe?: boolean;
  /** Appended after the editor's own extensions (mount.ts's outline push). */
  extraExtensions?: Extension;
}

function buildExtensions(
  actions: EditorActions,
  language: Language,
  opts: EditorOptions,
): Extension[] {
  const editorConfig = opts.config ?? defaultEditorConfig;
  const shared = [
    // WebKit on Mac Catalyst inserts a committed dead key twice; native host only.
    ...(opts.deadKeyDedupe ? [deadKeyCommitDedupe()] : []),

    // Memoized so viewport rebuilds don't repeat host round-trips. The cache
    // is per-mount, and mount.ts recreates the editor on every `init`.
    ...(opts.resolveAsset ? [assetResolverFacet.of(memoizedAssetResolver(opts.resolveAsset))] : []),
    ...(opts.workspaceAccess ? [workspaceAccessFacet.of(opts.workspaceAccess)] : []),
    ...(opts.loadMermaid ? [mermaidLoaderFacet.of(opts.loadMermaid)] : []),

    keymap.of(hsnipsKeymap),
    keymap.of([{ key: 'Tab', run: acceptCompletion }]),

    // indentWithTab is wired per-language AFTER taboutKeymap so Tabout gets
    // Tab first.
    keymap.of(closeBracketsKeymap),
    keymap.of(historyKeymap),
    search({ top: true, createPanel: chalkSearchPanel }),
    // Before searchKeymap so the toggle beats the stock open-only Mod-f, in
    // both scopes.
    keymap.of([{ key: 'Mod-f', run: toggleSearchPanel, scope: 'editor search-panel' }]),
    keymap.of(searchKeymap),
    // Home/End clamped to the caret's line: WebKit's line-boundary hit-test
    // overshoots near block widgets. Prec.high inside, so it beats defaultKeymap.
    horizontalNavKeymap,
    keymap.of(defaultKeymap),

    history(),
    bracketMatching(),
    closeBrackets(),
    drawSelection(),
    highlightSpecialChars(),
    // No highlightSelectionMatches(): match highlighting belongs to Cmd+F only.

    indentUnit.of('    '),

    EditorView.updateListener.of((update) => {
      if (update.docChanged) {
        actions.onContentChange(docText(update.state.doc));
      }
    }),

    // Gutter and wrapping live in vsCodeTheme so `editor-config` can toggle them.
    themeCompartment.of(vsCodeTheme(editorConfig)),

    // Swallow Cmd+P so it never reaches Catalyst's performKeyEquivalent, which
    // throws on key events the web view declines. On native, native-host.ts's
    // capture-phase listener takes it first; this is the backstop.
    keymap.of([{ key: 'Mod-p', run: () => true }]),

    hangingIndent(),
    comfortableBottom(),
    chromeTopMargin(),

    // Seeded from the host config so a re-init keeps the mode.
    editingModeCompartment.of(editingModeExtension(editorConfig.editingMode)),
    markdownTypesetCompartment.of(markdownTypesetExtension(editorConfig.markdownStyle)),
  ];

  if (language === 'tex') {
    // texListPlugin reads mathRegionsField (registered before this compartment)
    // to skip collapsing a fence whose merge host is a display-math widget.
    // Preview and Mixed share ONE math field instance: CM6 keeps a field's
    // value across a reconfigure that keeps it, so switching re-renders nothing.
    const texMath = texMathPlugin();
    const texSets: PreviewSets = {
      preview: [
        texFramePlugin(),
        texCalloutPlugin(texListLineCollapsed),
        texListPlugin(),
        texMath,
        texImagePlugin(),
        texConcealPlugin(),
        texLayoutDimPlugin(),
      ],
      mixed: [
        texFramePlugin({ conceal: false }),
        // No list fence collapses in Mixed, so nothing to move the callout
        // bottom off.
        texCalloutPlugin(() => false, { conceal: false }),
        texListPlugin({ conceal: false }),
        texMath,
        texImagePlugin(),
        texConcealPlugin({ conceal: false }),
        texLayoutDimPlugin(),
      ],
      source: [],
    };
    return [
      ...shared,
      // Freezes reveal-on-caret while a mouse gesture is in progress (via
      // reveal-gate.ts). Outside previewCompartment: harmless in source mode.
      pointerGestureExtension(),
      // Must precede texMathPlugin and hsnipsExtension so it has updated
      // before they read it.
      mathRegionsField,
      StreamLanguage.define(stex),
      syntaxHighlighting(texHighlightStyle),
      // After mathRegionsField, which it reads.
      texStyleRegionsField,
      texDecorationsPlugin(),
      viewModeExtension(texSets, editorConfig.viewMode),
      texFormatKeymap,
      // Up/Down stop ON a collapsed fence line and reveal it; the math keymap
      // steps INTO collapsed math. Their firing conditions are disjoint.
      texFrameFenceKeymap,
      texCalloutFenceKeymap,
      texListFenceKeymap,
      texMathArrowKeymap,
      // AFTER the stop keymaps (same Prec.high, later = lower): the default
      // move, snapped out of widget-rendered regions so transit never reveals
      // them. Inactive in source mode.
      texVerticalArrowKeymap(isSourceMode),
      hsnipsExtension({ isInMathContext: snippetMathContext(isInMathContextTex) }),
      latexCompletionExtension(),
      taboutKeymap(isInMathContextTex, 'tex'),
      itemNewlineKeymap(isInMathContextTex),
      mathWrapInputHandler(isInMathContextTex),
      keymap.of([indentWithTab]),
      placeholder('% Start typing LaTeX…'),
    ];
  }

  // tablePlugin before livePreviewPlugin so the block-replace claims Table
  // ranges first. One math instance for both sets, as in the tex branch.
  const mdMath = mathPlugin();
  const mdSets: PreviewSets = {
    preview: [
      mdMath,
      tablePlugin(),
      calloutPlugin(),
      livePreviewPlugin(),
      mdTypesetPlugin(),
      mdCrossrefPlugin(),
      frontmatterDimExtension(),
      codeBlockPlugin(),
      mermaidPlugin(),
    ],
    mixed: [
      mdMath,
      tablePlugin(),
      calloutPlugin({ conceal: false }),
      livePreviewPlugin({ conceal: false }),
      mdCrossrefPlugin({ conceal: false }),
      frontmatterDimExtension(),
      codeBlockPlugin(),
      mermaidPlugin(),
    ],
    source: [],
  };
  return [
    ...shared,
    // Before the preview sets, so its conceal-override field has updated
    // before they read it.
    pointerGestureExtension(),
    // frontmatterSyntax first so Setext/HorizontalRule can't claim a leading `---` block.
    markdown({
      extensions: [frontmatterSyntax, mathSyntax, highlightSyntax, Strikethrough, TaskList, Table],
      codeLanguages: mdCodeLanguages,
    }),
    // Nested fence languages only. Outside previewCompartment so code keeps
    // its colours in source mode.
    syntaxHighlighting(codeHighlightStyle),
    viewModeExtension(mdSets, editorConfig.viewMode),
    mdFormatKeymap,
    mdListNewlineKeymap(isInMathContextMd),
    // Fence stops, as in the tex branch.
    mdCalloutFenceKeymap,
    mdMathArrowKeymap,
    // AFTER the stop keymaps (same Prec.high, later = lower): keeps the goal
    // column across fence/math stops. Inactive in source mode.
    mdVerticalArrowKeymap(isSourceMode),
    hsnipsExtension({ isInMathContext: snippetMathContext(isInMathContextMd) }),
    mdCompletionExtension(),
    taboutKeymap(isInMathContextMd, 'md'),
    // After Tabout (math keeps its Tab) and before indentWithTab.
    mdListIndentKeymap(isInMathContextMd),
    mathWrapInputHandler(isInMathContextMd),
    keymap.of([indentWithTab]),
    placeholder('Start typing…'),
  ];
}

export function createEditorState(
  content: string,
  actions: EditorActions,
  language: Language,
  opts: EditorOptions = {},
): EditorState {
  return EditorState.create({
    doc: content,
    extensions: [buildExtensions(actions, language, opts), opts.extraExtensions ?? []],
  });
}

export function createEditor(
  parent: HTMLElement,
  content: string,
  actions: EditorActions,
  language: Language,
  opts: EditorOptions = {},
): EditorView {
  const view = new EditorView({
    state: createEditorState(content, actions, language, opts),
    parent,
  });
  view.focus();
  return view;
}
