import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';
import { userHsnipsDirs } from '../hsnips-paths';
import { defaultLatexHsnips } from '@chalk/editor-core/default-hsnips';

/**
 * In md these colours only paint fenced code (editor-core's
 * codeHighlightStyle), so the candidates are generic scope tails with no
 * language suffix. `tagName` and `bracket` stay empty: fenced code has no tag
 * rule, and brackets keep the editor foreground as in VS Code.
 */
const MD_SCOPE_CANDIDATES: Record<keyof ThemeColors, string[]> = {
  keyword: ['keyword', 'keyword.control', 'storage.type'],
  tagName: [],
  comment: ['comment'],
  number: ['constant.numeric', 'constant'],
  atom: ['constant.language', 'constant'],
  bracket: [],
  specialVariable: ['entity.name.function', 'support.function'],
  invalid: ['invalid'],
};

/**
 * `latex.hsnips` + `markdown.hsnips` from the first user dir holding either;
 * otherwise the bundled latex snippets, so `$…$` math still gets them.
 */
function loadMarkdownHsnips(): string | null {
  const parts: string[] = [];
  for (const dir of userHsnipsDirs()) {
    for (const fname of ['latex.hsnips', 'markdown.hsnips']) {
      const filePath = path.join(dir, fname);
      if (existsSync(filePath)) {
        parts.push(readFileSync(filePath, 'utf8'));
      }
    }
    if (parts.length > 0) break;
  }
  if (parts.length > 0) return parts.join('\n');
  return defaultLatexHsnips;
}

export const markdownProfile: LanguageProfile = {
  id: 'md',
  viewType: 'chalk.markdownEditor',
  settingsLanguageId: 'markdown',
  themeScopeCandidates: MD_SCOPE_CANDIDATES,
  loadHsnips: loadMarkdownHsnips,
};
