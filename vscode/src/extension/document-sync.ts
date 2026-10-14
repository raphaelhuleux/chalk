import * as vscode from 'vscode';

/**
 * The single replacement (common prefix and suffix kept) that turns `oldText`
 * into `newText`. A whole-document replace would move the caret of other
 * editors on the document and store a full copy per keystroke in undo.
 *
 * Like editor-core's diffReplace, but a boundary never falls inside a
 * surrogate pair or a CRLF: VS Code widens such a range while keeping the
 * insert's lone half (corrupting the character), and positionAt clamps an
 * offset inside an EOL.
 */
export function minimalReplace(
  oldText: string,
  newText: string,
): { from: number; to: number; insert: string } {
  const minLen = Math.min(oldText.length, newText.length);
  let prefix = 0;
  while (prefix < minLen && oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)) {
    prefix++;
  }
  while (prefix > 0 && (splitsPair(oldText, prefix) || splitsPair(newText, prefix))) {
    prefix--;
  }

  let suffix = 0;
  const maxSuffix = minLen - prefix;
  while (
    suffix < maxSuffix &&
    oldText.charCodeAt(oldText.length - 1 - suffix) ===
      newText.charCodeAt(newText.length - 1 - suffix)
  ) {
    suffix++;
  }
  while (
    suffix > 0 &&
    (splitsPair(oldText, oldText.length - suffix) ||
      splitsPair(newText, newText.length - suffix))
  ) {
    suffix--;
  }

  return {
    from: prefix,
    to: oldText.length - suffix,
    insert: newText.slice(prefix, newText.length - suffix),
  };
}

/** Does offset `i` fall between the two halves of a surrogate pair or of a
 *  CRLF? */
function splitsPair(text: string, i: number): boolean {
  if (i <= 0 || i >= text.length) return false;
  const before = text.charCodeAt(i - 1);
  const after = text.charCodeAt(i);
  if (before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) return true;
  return before === 0x0d && after === 0x0a;
}

/**
 * The engine's text in the document's line endings: CM6 always joins with
 * `\n`, so a CRLF file must be compared and diffed in CRLF.
 */
export function toDocumentEol(text: string, eol: vscode.EndOfLine): string {
  if (eol !== vscode.EndOfLine.CRLF) {
    return text.includes('\r') ? text.replace(/\r\n?/g, '\n') : text;
  }
  return text.replace(/\r\n|\r|\n/g, '\r\n');
}

export interface EditQueueHooks {
  document: vscode.TextDocument;
  applyEdit: (edit: vscode.WorkspaceEdit) => Thenable<boolean>;
  /** Push the document's text back to the webview after a refused edit. */
  resync: (text: string) => void;
  log: (message: string) => void;
}

/**
 * The webview → TextDocument half of one panel's sync. Each `edit` carries the
 * whole text; only the newest matters.
 *
 * Serialized, one `applyEdit` in flight: VS Code stamps a WorkspaceEdit with
 * the document version when applyEdit is CALLED and rejects it if the document
 * moved on, so two back-to-back edits (an hsnips expansion) would lose the
 * second.
 */
export class WebviewEditQueue {
  private latest: string | null = null;
  private applying: string | null = null;
  private draining = false;
  private drained: Promise<void> = Promise.resolve();

  constructor(private readonly hooks: EditQueueHooks) {}

  /** Queue the webview's text. Resolves once the queue is empty again. */
  push(text: string): Promise<void> {
    this.latest = text;
    if (!this.draining) {
      this.draining = true;
      this.drained = this.drain();
    }
    return this.drained;
  }

  /**
   * Whether a document change is the echo of this panel's in-flight edit.
   * Matched on the text, not on "an edit is in flight", so a change made
   * elsewhere during the round-trip is still forwarded.
   */
  isOwnEdit(documentText: string): boolean {
    return this.applying !== null && documentText === this.applying;
  }

  private async drain(): Promise<void> {
    const { document } = this.hooks;
    try {
      while (this.latest !== null) {
        const target = toDocumentEol(this.latest, document.eol);
        this.latest = null;
        const current = document.getText();
        if (target === current) continue;

        const { from, to, insert } = minimalReplace(current, target);
        const edit = new vscode.WorkspaceEdit();
        edit.replace(
          document.uri,
          new vscode.Range(document.positionAt(from), document.positionAt(to)),
          insert,
        );
        this.applying = target;
        let applied = false;
        try {
          applied = await this.hooks.applyEdit(edit);
        } catch (e) {
          this.hooks.log(`applyEdit threw: ${e instanceof Error ? e.message : String(e)}`);
        } finally {
          this.applying = null;
        }
        if (!applied) {
          // Anything still queued was computed from the pre-change buffer and
          // would overwrite that change: drop it and resync the webview.
          this.latest = null;
          this.hooks.log('applyEdit was rejected; resyncing the webview from the document.');
          this.hooks.resync(document.getText());
        }
      }
    } finally {
      this.draining = false;
    }
  }
}
