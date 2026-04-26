import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';
import bundledLatexHsnips from '../../../assets/latex.hsnips';

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
 * Loads hsnips for markdown editing. Resolution order:
 *   1. User dir (`hsnips.hsnipsPath` setting OR `~/.config/hsnips/`):
 *      tries `latex.hsnips` AND `markdown.hsnips`, concatenates both if
 *      present. The first directory with at least one file wins.
 *   2. Falls back to the bundled `assets/latex.hsnips` so markdown's
 *      `$…$` regions still get math snippets out of the box.
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

  if (parts.length > 0) return parts.join('\n');
  return bundledLatexHsnips;
}

export const markdownProfile: LanguageProfile = {
  id: 'md',
  viewType: 'chalk.markdownEditor',
  themeScopeCandidates: MD_SCOPE_CANDIDATES,
  loadHsnips: loadMarkdownHsnips,
};
