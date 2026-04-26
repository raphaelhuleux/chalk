import { existsSync, readFileSync } from 'fs';
import * as path from 'path';
import type { LanguageProfile } from './types';
import type { ThemeColors } from '../theme-reader';
import { userHsnipsDirs } from '../hsnips-paths';
import bundledLatexHsnips from '../../../assets/latex.hsnips';

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
 * Loads `latex.hsnips` for the tex editor. Resolution order:
 *   1. `hsnips.hsnipsPath` setting (compatible with the real HyperSnips
 *      extension's setting, so users with that extension installed get
 *      the same snippets here automatically).
 *   2. `~/.config/hsnips/latex.hsnips`.
 *   3. The default `assets/latex.hsnips` bundled with this extension —
 *      a curated set of math snippets so users without an existing
 *      hsnips setup get sensible defaults out of the box.
 *
 * The user's file fully overrides the bundled default; we don't merge.
 * Anyone who wants to extend rather than replace can copy
 * `assets/latex.hsnips` to `~/.config/hsnips/` and edit from there.
 */
function loadLatexHsnips(): string | null {
  for (const dir of userHsnipsDirs()) {
    const filePath = path.join(dir, 'latex.hsnips');
    if (existsSync(filePath)) {
      return readFileSync(filePath, 'utf8');
    }
  }
  return bundledLatexHsnips;
}

export const texProfile: LanguageProfile = {
  id: 'tex',
  viewType: 'chalk.texEditor',
  themeScopeCandidates: TEX_SCOPE_CANDIDATES,
  loadHsnips: loadLatexHsnips,
};
