import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';
import { userHsnipsDirs } from '../hsnips-paths';
import { defaultLatexHsnips } from '@chalk/editor-core/default-hsnips';

const TEX_SCOPE_CANDIDATES: Record<keyof ThemeColors, string[]> = {
  keyword: [
    'support.function.be.latex',
    'keyword.control.preamble.latex',
    'support.function.general.latex',
    'keyword.control.latex',
    'support.function.latex',
    'entity.name.function.latex',
    'keyword.control',
    'support.function',
    'entity.name.function',
    'keyword',
  ],
  tagName: [
    'entity.name.function.environment.latex',
    'support.class.latex',
    'entity.name.type.environment.latex',
    'entity.name.function.latex',
    'entity.name.type.latex',
    'entity.name.type',
    'support.class',
    'entity.name.tag',
    'entity.name',
    'variable.parameter',
  ],
  comment: [
    'comment.line.percentage.latex',
    'comment.line.percentage',
    'comment.line',
    'comment',
  ],
  number: ['constant.numeric.latex', 'constant.numeric', 'constant'],
  atom: [
    'constant.character.latex',
    'constant.character',
    'constant.language',
    'constant.other',
    'constant',
  ],
  bracket: [
    'punctuation.definition.arguments.begin.latex',
    'punctuation.definition.arguments',
    'punctuation.definition',
    'punctuation.section',
    'punctuation',
  ],
  specialVariable: [
    'variable.parameter.function.latex',
    'variable.parameter.latex',
    'variable.parameter',
    'variable.other',
    'variable',
  ],
  invalid: ['invalid.illegal', 'invalid.deprecated', 'invalid'],
};

/**
 * The first user `latex.hsnips` (`hsnips.hsnipsPath` is the HyperSnips
 * extension's own setting), else editor-core's bundled default. The user's
 * file replaces the default; no merge.
 */
function loadLatexHsnips(): string | null {
  for (const dir of userHsnipsDirs()) {
    const filePath = path.join(dir, 'latex.hsnips');
    if (existsSync(filePath)) {
      return readFileSync(filePath, 'utf8');
    }
  }
  return defaultLatexHsnips;
}

export const texProfile: LanguageProfile = {
  id: 'tex',
  viewType: 'chalk.texEditor',
  settingsLanguageId: 'latex',
  themeScopeCandidates: TEX_SCOPE_CANDIDATES,
  loadHsnips: loadLatexHsnips,
};
