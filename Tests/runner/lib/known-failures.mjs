/**
 * Tagged known-failures files, shared by the browser harnesses.
 *
 * Each non-comment line is
 *
 *   <path-or-name> [@tag1,tag2]
 *
 * The name may contain spaces (browser-test entries are `scenario :: check`);
 * the tag list, when present, is the line's trailing whitespace-separated
 * token and starts with `@`. An entry with no tag list applies to EVERY tag,
 * which keeps the pre-existing untagged line in Tests/fixtures/KNOWN_FAILURES.txt
 * meaning exactly what it meant before lanes existed. `#` starts a comment.
 */
import { existsSync, readFileSync } from 'node:fs';

export function loadKnownFailures(file, label = file) {
  // name -> null (all tags) | Set of tags
  const entries = new Map();
  if (existsSync(file)) {
    for (const raw of readFileSync(file, 'utf8').split('\n')) {
      const line = raw.replace(/#.*$/, '').trim();
      if (!line) continue;
      const tagged = /^(.*\S)\s+@([A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+)*)$/.exec(line);
      const name = tagged ? tagged[1] : line;
      const tags = tagged ? new Set(tagged[2].split(',')) : null;
      if (entries.has(name)) {
        const prev = entries.get(name);
        // Two lines for one name union their tags; any untagged line wins.
        if (prev === null || tags === null) entries.set(name, null);
        else for (const t of tags) prev.add(t);
      } else {
        entries.set(name, tags);
      }
    }
  }

  return {
    file,
    /** Is `name` expected to fail under `tag`? */
    isKnown(name, tag) {
      if (!entries.has(name)) return false;
      const tags = entries.get(name);
      return tags === null || tags.has(tag);
    },
    /** Message for a listed entry that passed — the run must fail on it. */
    formatUnexpectedPass(name, tag) {
      const tags = entries.get(name);
      const scope = tags === null ? 'the entry' : `the @${tag} tag`;
      return `${name} passes under ${tag} but is listed in ${label}; remove ${scope}`;
    },
  };
}
