import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import * as vscode from 'vscode';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';

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
 * Loads `latex.hsnips` from the user's HyperSnips directory. Checks the
 * `hsnips.hsnipsPath` setting first (compatible with the real HyperSnips
 * extension), then falls back to ~/.config/hsnips.
 */
function loadLatexHsnips(): string | null {
  const config = vscode.workspace.getConfiguration('hsnips');
  const customPath = config.get<string>('hsnipsPath');
  const searchDirs = [
    customPath,
    path.join(process.env.HOME || '', '.config', 'hsnips'),
  ].filter(Boolean) as string[];

  for (const dir of searchDirs) {
    const filePath = path.join(dir, 'latex.hsnips');
    if (existsSync(filePath)) {
      return readFileSync(filePath, 'utf8');
    }
  }
  return null;
}

export const texProfile: LanguageProfile = {
  id: 'tex',
  viewType: 'chalk.texEditor',
  allowedWebviewCommands: new Set(['chalk.build']),
  themeScopeCandidates: TEX_SCOPE_CANDIDATES,
  loadHsnips: loadLatexHsnips,
};
