import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';

/**
 * Directories searched for user `.hsnips` files, in resolution order. Shared
 * by the language profiles (reading) and the provider (hot-reload watchers).
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
