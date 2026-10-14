import {
  LanguageDescription,
  LanguageSupport,
  StreamLanguage,
} from '@codemirror/language';
import type { StreamParser } from '@codemirror/language';
import { python } from '@codemirror/legacy-modes/mode/python';
import { r } from '@codemirror/legacy-modes/mode/r';
import { julia } from '@codemirror/legacy-modes/mode/julia';

// Fence info string (```python, or Quarto ```{r, echo=false}) to a nested
// language. `LanguageDescription.matchLanguageName` can't strip the Quarto
// braces, hence the function form of `codeLanguages`.

function support(parser: StreamParser<unknown>): () => Promise<LanguageSupport> {
  const lang = new LanguageSupport(StreamLanguage.define(parser));
  return () => Promise.resolve(lang);
}

const descriptions: LanguageDescription[] = [
  LanguageDescription.of({ name: 'python', alias: ['py', 'python3'], load: support(python) }),
  LanguageDescription.of({ name: 'r', load: support(r) }),
  LanguageDescription.of({ name: 'julia', alias: ['jl'], load: support(julia) }),
];

const byName = new Map<string, LanguageDescription>();
for (const desc of descriptions) {
  byName.set(desc.name, desc);
  for (const alias of desc.alias) byName.set(alias, desc);
}

/** Fence info to a bare lowercase language token: `{python, echo=false}` and
 *  `{.python}` give `python`, a bare fence gives ``. */
export function normalizeFenceInfo(info: string): string {
  let s = info.trim();
  if (s.startsWith('{')) s = s.slice(1, s.endsWith('}') ? -1 : s.length);
  s = s.replace(/^[.,\s]+/, '');
  const m = /^[A-Za-z][A-Za-z0-9+#-]*/.exec(s);
  return m ? m[0].toLowerCase() : '';
}

/** Languages that highlight inside a fence. Completion offers only these, so
 *  it never suggests a fence that renders unhighlighted. */
export const fenceLanguageNames: string[] = descriptions.map((d) => d.name);

/** `codeLanguages` hook for `markdown()`: null for languages we don't ship. */
export function mdCodeLanguages(info: string): LanguageDescription | null {
  return byName.get(normalizeFenceInfo(info)) ?? null;
}
