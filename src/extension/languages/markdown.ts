import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';

const MD_SCOPE_CANDIDATES: Record<keyof ThemeColors, string[]> = {
  keyword: [],
  tagName: [],
  comment: [],
  number: [],
  atom: [],
  bracket: [],
  specialVariable: [],
  invalid: [],
};

/**
 * Loads hsnips for markdown editing. Always tries `latex.hsnips` (because
 * markdown's `$…$` regions use the same LaTeX math snippets) and
 * additionally `markdown.hsnips` if it exists. Returns concatenated text.
 */
function loadMarkdownHsnips(): string | null {
  const config = vscode.workspace.getConfiguration('hsnips');
  const customPath = config.get<string>('hsnipsPath');
  const searchDirs = [
    customPath,
    path.join(process.env.HOME || '', '.config', 'hsnips'),
  ].filter(Boolean) as string[];

  const parts: string[] = [];
  for (const dir of searchDirs) {
    for (const fname of ['latex.hsnips', 'markdown.hsnips']) {
      const filePath = path.join(dir, fname);
      if (existsSync(filePath)) {
        parts.push(readFileSync(filePath, 'utf8'));
      }
    }
    if (parts.length > 0) break;
  }
  return parts.length > 0 ? parts.join('\n') : null;
}

export const markdownProfile: LanguageProfile = {
  id: 'md',
  viewType: 'chalk.markdownEditor',
  allowedWebviewCommands: new Set(),
  themeScopeCandidates: MD_SCOPE_CANDIDATES,
  loadHsnips: loadMarkdownHsnips,
};
