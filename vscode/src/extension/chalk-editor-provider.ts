import * as vscode from 'vscode';
import { existsSync } from 'node:fs';
import { readdir, readFile, stat } from 'node:fs/promises';
import { dirname } from 'node:path';
import {
  answerAssetRequest,
  listWorkspaceFiles,
  readWorkspaceText,
} from './asset-resolver';
import { WebviewEditQueue } from './document-sync';
import { getWebviewHtml, generateNonce } from './webview-html';
import { WebviewWatchdog, CHECK_MS } from './webview-watchdog';
import { readThemeColors } from './theme-reader';
import { getMarkdownHeadingColors } from './markdown-heading-colors';
import { userHsnipsDirs } from './hsnips-paths';
import type { LanguageProfile } from './languages/types';

/**
 * Schemes the webview may ask the host to open; `open-external` is untrusted
 * input, so everything else (`file:`, `command:`, ...) is rejected.
 */
const SAFE_EXTERNAL_SCHEMES = new Set(['http', 'https', 'mailto']);

export class ChalkEditorProvider implements vscode.CustomTextEditorProvider {
  /** Ready webviews by document URI, for `revealLine`. */
  private readonly readyPanels = new Map<string, vscode.WebviewPanel>();

  constructor(
    private readonly context: vscode.ExtensionContext,
    private readonly profile: LanguageProfile,
    private readonly diagChannel: vscode.OutputChannel,
  ) {}

  /** Move the caret of `uri`'s Chalk editor to `line` (1-based). Transport
   *  glue like `heartbeat`, outside the HostPort protocol. False when no
   *  ready Chalk editor shows that document. */
  public revealLine(uri: vscode.Uri, line: number): boolean {
    const panel = this.readyPanels.get(uri.toString());
    if (!panel) return false;
    void panel.webview.postMessage({ type: 'goto-line', line });
    return true;
  }

  public async resolveCustomTextEditor(
    document: vscode.TextDocument,
    webviewPanel: vscode.WebviewPanel,
    _token: vscode.CancellationToken,
  ): Promise<void> {
    webviewPanel.webview.options = {
      enableScripts: true,
      localResourceRoots: [
        vscode.Uri.joinPath(this.context.extensionUri, 'dist'),
      ],
    };

    const nonce = generateNonce();
    webviewPanel.webview.html = getWebviewHtml(
      webviewPanel.webview,
      this.context.extensionUri,
      nonce,
    );

    const docKey = document.uri.toString();
    const diag = this.diagChannel;

    let webviewReady = false;

    // Nothing to buffer before `ready`: the `init` that answers it carries
    // document.getText(), which already holds every change made meanwhile.
    const postUpdate = (text: string): void => {
      if (!webviewReady) return;
      webviewPanel.webview.postMessage({ type: 'update', text });
    };

    const logAsyncError = (op: string, e: unknown): void => {
      const msg =
        e instanceof Error ? `${e.message}\n${e.stack ?? ''}` : String(e);
      diag.appendLine(`[chalk] ${op} failed: ${msg}`);
    };

    // Echo suppression must be PANEL-local: per-document suppression would
    // leave a sibling pane stale, and its next keystroke would send that stale
    // document and revert this pane's edits.
    const edits = new WebviewEditQueue({
      document,
      applyEdit: (edit) => vscode.workspace.applyEdit(edit),
      resync: postUpdate,
      log: (m) => diag.appendLine(`[chalk] ${m}`),
    });

    const postThemeColors = async (): Promise<void> => {
      try {
        const colors = await readThemeColors(this.profile.themeScopeCandidates);
        if (!colors) return;
        webviewPanel.webview.postMessage({ type: 'theme-colors', colors });
      } catch (e) {
        logAsyncError('postThemeColors', e);
      }
    };

    const postHeadingColors = async (): Promise<void> => {
      // Both profiles: tex headings (tex-conceal-plugin) use the palette too.
      try {
        const colors = await getMarkdownHeadingColors();
        webviewPanel.webview.postMessage({ type: 'heading-colors', colors });
      } catch (e) {
        logAsyncError('postHeadingColors', e);
      }
    };

    // Read through the language scope so `[markdown]` / `[latex]` blocks
    // apply. Raw values: the webview sanitizes them (sanitizeEditorConfig).
    const readEditorConfig = (): Record<string, unknown> => {
      const cfg = vscode.workspace.getConfiguration('editor', {
        uri: document.uri,
        languageId: this.profile.settingsLanguageId,
      });
      return {
        wordWrap: cfg.get('wordWrap'),
        wordWrapColumn: cfg.get('wordWrapColumn'),
        cursorWidth: cfg.get('cursorWidth'),
        cursorBlinking: cfg.get('cursorBlinking'),
        lineNumbers: cfg.get('lineNumbers'),
        lineNumbersMinChars: cfg.get('lineNumbersMinChars'),
        scrollbarVertical: cfg.get('scrollbar.vertical'),
        viewMode: vscode.workspace.getConfiguration('chalk', document.uri).get('viewMode'),
      };
    };

    const postHsnips = (): void => {
      const content = this.profile.loadHsnips();
      if (content === null) return;
      webviewPanel.webview.postMessage({ type: 'hsnips', content });
    };

    // Otherwise the silent fallback leaves users believing their custom
    // snippets loaded.
    const warnInvalidHsnipsPath = (): void => {
      const setting = vscode.workspace
        .getConfiguration('hsnips')
        .get<string>('hsnipsPath');
      if (setting && !existsSync(setting)) {
        diag.appendLine(
          `[chalk] hsnips.hsnipsPath="${setting}" does not exist on disk — bundled snippets used as fallback.`,
        );
      }
    };
    warnInvalidHsnipsPath();

    // Blank-editor self-healing: a silent visible webview gets its HTML
    // rebuilt (fresh nonce) and re-inits from the host-side document.
    // `webviewReady` drops first so changes are not posted into a dead page;
    // the reload's `init` carries them.
    const reloadWebview = (): void => {
      webviewReady = false;
      webviewPanel.webview.html = getWebviewHtml(
        webviewPanel.webview,
        this.context.extensionUri,
        generateNonce(),
      );
    };
    const watchdog = new WebviewWatchdog({
      isVisible: () => webviewPanel.visible,
      now: () => Date.now(),
      log: (m) => diag.appendLine(`[chalk] ${m}`),
      reload: reloadWebview,
      // "Reload Editor" re-arms the budget and retries immediately.
      onGiveUp: () => {
        void vscode.window
          .showErrorMessage(
            'Chalk editor stopped responding after repeated reloads.',
            'Reload Editor',
          )
          .then((choice) => {
            if (choice !== 'Reload Editor') return;
            watchdog.reset();
            reloadWebview();
          });
      },
    });
    const watchdogTimer = setInterval(() => watchdog.check(), CHECK_MS);

    const documentDir = document.uri.scheme === 'file' ? dirname(document.uri.fsPath) : null;

    const messageSub = webviewPanel.webview.onDidReceiveMessage(async (msg) => {
      // A `client-error` must NOT count as liveness: a bundle that crashes on
      // boot posts one per reload, and markAlive would reset the reload
      // budget, looping reloads forever.
      if (msg.type !== 'client-error') watchdog.markAlive();
      switch (msg.type) {
        // VS Code glue from webview-entry.ts, not HostPort messages.
        case 'heartbeat':
          return;
        case 'client-error': {
          diag.appendLine(
            `[chalk] webview error: ${String(msg.message)}${
              msg.stack ? `\n${String(msg.stack)}` : ''
            }`,
          );
          return;
        }
        case 'ready': {
          webviewReady = true;
          this.readyPanels.set(docKey, webviewPanel);
          webviewPanel.webview.postMessage({
            type: 'init',
            text: document.getText(),
            language: this.profile.id,
            editorConfig: readEditorConfig(),
          });
          void postThemeColors();
          void postHeadingColors();
          postHsnips();
          return;
        }
        case 'edit': {
          if (typeof msg.text !== 'string') return;
          void edits.push(msg.text);
          return;
        }
        // Request/reply glue (not HostPort). Null url on any failure; the
        // editor shows its missing-image placeholder.
        case 'resolve-asset': {
          if (typeof msg.id !== 'number') return;
          const url = await answerAssetRequest(msg.src, {
            documentDir,
            isTex: this.profile.id === 'tex',
            documentText: () => document.getText(),
            fileExists: existsSync,
            readFile,
          });
          webviewPanel.webview.postMessage({
            type: 'resolve-asset-reply',
            id: msg.id,
            url,
          });
          return;
        }
        case 'list-files': {
          if (typeof msg.id !== 'number') return;
          const paths = await listWorkspaceFiles(msg.kinds, {
            documentDir,
            readDir: async (dir) =>
              (await readdir(dir, { withFileTypes: true })).map((e) => ({
                name: e.name,
                isDirectory: e.isDirectory(),
              })),
          });
          webviewPanel.webview.postMessage({
            type: 'list-files-reply',
            id: msg.id,
            paths,
          });
          return;
        }
        case 'read-text': {
          if (typeof msg.id !== 'number') return;
          const text = await readWorkspaceText(msg.path, {
            documentDir,
            readText: (filePath) => readFile(filePath, 'utf8'),
            fileSize: async (filePath) => (await stat(filePath)).size,
          });
          webviewPanel.webview.postMessage({
            type: 'read-text-reply',
            id: msg.id,
            text,
          });
          return;
        }
        case 'open-external': {
          if (typeof msg.url !== 'string') return;
          let uri: vscode.Uri;
          try {
            uri = vscode.Uri.parse(msg.url, true);
          } catch {
            diag.appendLine(
              `[chalk] open-external rejected unparsable URL: ${msg.url}`,
            );
            return;
          }
          // Schemes are case-insensitive (RFC 3986).
          if (!SAFE_EXTERNAL_SCHEMES.has(uri.scheme.toLowerCase())) {
            diag.appendLine(
              `[chalk] open-external rejected scheme "${uri.scheme}" — only ${[...SAFE_EXTERNAL_SCHEMES].join('/')} allowed.`,
            );
            return;
          }
          void vscode.env.openExternal(uri);
          return;
        }
      }
    });

    const changeSub = vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.toString() !== docKey) return;
      // A save fires this with no content change, just the dirty flag.
      if (e.contentChanges.length === 0) return;
      const text = e.document.getText();
      if (edits.isOwnEdit(text)) return;
      postUpdate(text);
    });

    // No `update` on becoming visible: retainContextWhenHidden (index.ts)
    // keeps a hidden webview live, so changeSub already posted every change.
    const viewStateSub = webviewPanel.onDidChangeViewState(() => {
      watchdog.markVisibilityChange();
    });

    const themeSub = vscode.window.onDidChangeActiveColorTheme(() => {
      if (webviewReady) {
        void postThemeColors();
        void postHeadingColors();
      }
    });

    // Hot-reload hsnips on external edits; watchers are recreated when
    // hsnips.hsnipsPath changes.
    let hsnipsWatchers: vscode.FileSystemWatcher[] = [];
    const disposeHsnipsWatchers = (): void => {
      for (const w of hsnipsWatchers) w.dispose();
      hsnipsWatchers = [];
    };
    const installHsnipsWatchers = (): void => {
      disposeHsnipsWatchers();
      hsnipsWatchers = userHsnipsDirs()
        .filter((dir) => existsSync(dir))
        .map((dir) => {
          const watcher = vscode.workspace.createFileSystemWatcher(
            new vscode.RelativePattern(vscode.Uri.file(dir), '*.hsnips'),
          );
          const reload = (): void => {
            if (webviewReady) postHsnips();
          };
          watcher.onDidChange(reload);
          watcher.onDidCreate(reload);
          watcher.onDidDelete(reload);
          return watcher;
        });
    };
    installHsnipsWatchers();

    // Color customizations fire onDidChangeConfiguration, not
    // onDidChangeActiveColorTheme.
    const configSub = vscode.workspace.onDidChangeConfiguration((e) => {
      if (!webviewReady) return;
      if (
        e.affectsConfiguration('workbench.colorTheme') ||
        e.affectsConfiguration('workbench.colorCustomizations') ||
        e.affectsConfiguration('editor.tokenColorCustomizations')
      ) {
        void postThemeColors();
        void postHeadingColors();
      }
      if (e.affectsConfiguration('hsnips.hsnipsPath')) {
        warnInvalidHsnipsPath();
        installHsnipsWatchers();
        postHsnips();
      }
      if (
        e.affectsConfiguration('chalk.viewMode', document.uri) ||
        e.affectsConfiguration('editor', {
          uri: document.uri,
          languageId: this.profile.settingsLanguageId,
        })
      ) {
        webviewPanel.webview.postMessage({
          type: 'editor-config',
          config: readEditorConfig(),
        });
      }
    });

    webviewPanel.onDidDispose(() => {
      // An edit still in flight may want to resync; the webview is gone.
      webviewReady = false;
      if (this.readyPanels.get(docKey) === webviewPanel) this.readyPanels.delete(docKey);
      clearInterval(watchdogTimer);
      messageSub.dispose();
      changeSub.dispose();
      viewStateSub.dispose();
      themeSub.dispose();
      configSub.dispose();
      disposeHsnipsWatchers();
    });
  }
}
