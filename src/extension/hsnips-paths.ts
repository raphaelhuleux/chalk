import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';

/**
 * Returns the absolute directory paths where chalk looks for user
 * `.hsnips` files, in resolution order:
 *   1. `hsnips.hsnipsPath` setting (if set)
 *   2. `~/.config/hsnips/`
 *
 * Used both by language profiles (to read snippets) and by the editor
 * provider (to install a FileSystemWatcher so external edits hot-reload).
 */
export function userHsnipsDirs(): string[] {
  const customPath = vscode.workspace
    .getConfiguration('hsnips')
    .get<string>('hsnipsPath');
  return [
    customPath,
    path.join(os.homedir(), '.config', 'hsnips'),
  ].filter((d): d is string => Boolean(d));
}
