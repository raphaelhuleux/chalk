/**
 * Parses `.hsnips` files into snippet descriptors.
 *
 * Adapted from draivin/hsnips (HyperSnips for VS Code) `parser.ts` +
 * `hsnippet.ts`, MIT License, Copyright (c) 2019 Ian Ornelas — full license
 * text in THIRD-PARTY-NOTICES at the repo root. Stripped of VS Code
 * dependencies and the dynamic code generation (new Function / eval).
 * Inline JS blocks (`\`\`…\`\``) are never run: a bare capture reference is
 * rewritten to `#N`, any other JS is dropped.
 */

// ── Data types ──────────────────────────────────────────────────────

export interface HSnippet {
  trigger: string;
  regexp?: RegExp;
  /** Regex source as written, before anchoring: the `# chalk-disable:` key
   *  for regex snippets. */
  regexpSource?: string;
  description: string;
  body: string;
  /** Captures whose `#N` is trimmed (the `` `rv = m[N].trim()` `` form).
   *  Out of band so no in-body marker can collide with real LaTeX. */
  trimmedCaptures?: Set<number>;
  automatic: boolean;
  inword: boolean;
  wordboundary: boolean;
  /** `b` flag: only whitespace may precede the trigger on its line. */
  beginofline: boolean;
  /** Context filter source. Never eval'd: only `math(context)` and
   *  `!math(context)` are recognised (see hsnips-plugin.ts). */
  contextFilter?: string;
  priority: number;
}

// ── Parser ──────────────────────────────────────────────────────────

const HEADER_RE = /^snippet ?(?:`([^`]+)`|(\S+))?(?: "([^"]+)")?(?: ([AMiwb]*))?/;

/**
 * Chalk extension: `# chalk-disable: <key> ...` anywhere in the file removes
 * snippets by trigger, or by backtick-quoted regex source (regexes may
 * contain spaces). Other hsnips consumers see an ordinary comment.
 */
const DISABLE_RE = /^#\s*chalk-disable:\s*(.*)$/;

function parseDisableKeys(rest: string, into: Set<string>): void {
  for (const m of rest.matchAll(/`([^`]+)`|(\S+)/g)) {
    into.add(m[1] ?? m[2]);
  }
}

/**
 * hsnips reaches regex captures through inline JS, which we don't run: a bare
 * capture reference becomes Chalk's `#N` (leaving `$N` for tab stops) and any
 * other JS is dropped.
 */
const CAPTURE_JS_RE = /^\s*rv\s*=\s*m\[(\d+)\]\s*(\.trim\(\))?\s*;?\s*$/;

function rewriteInlineJs(line: string, trimmed: Set<number>): string {
  return line.replace(/``([^`]*)``/g, (_full, js: string) => {
    const m = CAPTURE_JS_RE.exec(js);
    if (!m) return '';
    const index = Number(m[1]);
    if (m[2]) trimmed.add(index);
    return `#${index}`;
  });
}

function parseBody(lines: string[]): { body: string; trimmedCaptures: Set<number> } {
  const out: string[] = [];
  const trimmedCaptures = new Set<number>();
  let inCode = false;

  while (lines.length > 0) {
    const line = lines.shift();
    if (line === undefined) break;

    if (inCode) {
      if (line.includes('``')) {
        const afterClose = line.split('``').slice(1).join('``');
        if (afterClose) {
          const stripped = rewriteInlineJs(afterClose, trimmedCaptures);
          if (stripped) out.push(stripped);
        }
        inCode = false;
      }
      continue;
    }

    if (line.startsWith('endsnippet')) break;

    if (!line.includes('``')) {
      out.push(line);
      continue;
    }

    const tickCount = (line.match(/``/g) || []).length;

    if (tickCount % 2 === 0) {
      out.push(rewriteInlineJs(line, trimmedCaptures));
    } else {
      // Odd count: the last `` opens a multi-line block. Keep the text
      // outside the pairs; the JS inside them is dropped, not rewritten.
      const parts = line.split('``');
      let result = '';
      for (let i = 0; i < parts.length - 1; i += 2) {
        result += parts[i];
      }
      if (result) out.push(result);
      inCode = true;
    }
  }

  return { body: out.join('\n'), trimmedCaptures };
}

export function parseHSnips(content: string): HSnippet[] {
  const lines = content.split(/\r?\n/);
  const snippets: HSnippet[] = [];
  let priority = 0;
  let context: string | undefined;
  let inGlobal = false;
  const disabled = new Set<string>();

  while (lines.length > 0) {
    const line = lines.shift();
    if (line === undefined) break;

    if (inGlobal) {
      if (line.startsWith('endglobal')) inGlobal = false;
      continue;
    }

    if (line.startsWith('#')) {
      const d = DISABLE_RE.exec(line);
      if (d) parseDisableKeys(d[1], disabled);
      continue;
    }
    if (line.startsWith('global')) { inGlobal = true; continue; }
    if (line.startsWith('priority ')) {
      priority = Number(line.substring('priority '.length).trim()) || 0;
      continue;
    }
    if (line.startsWith('context ')) {
      context = line.substring('context '.length).trim() || undefined;
      continue;
    }

    const m = HEADER_RE.exec(line);
    if (!m) continue;

    const flags = m[4] || '';
    let trigger = m[2] || '';
    let regexp: RegExp | undefined;
    let regexpSource: string | undefined;

    if (m[1]) {
      // Anchor by wrapping: a trailing `$` may be an escaped literal and
      // `foo|bar$` anchors only one branch. An unanchored match mid-line
      // would make `findMatch` eat everything up to the caret. Non-capturing,
      // so `#N` indices are unaffected.
      try {
        regexp = new RegExp(`(?:${m[1]})$`, 'm');
        regexpSource = m[1];
        trigger = '';
      } catch {
        // A pattern JS rejects: drop the snippet, keep the file. The body
        // must still be consumed or its lines would parse as snippets.
        console.warn(
          `[chalk hsnips] snippet regex \`${m[1]}\` is not valid — snippet skipped.`,
        );
        parseBody(lines);
        priority = 0;
        context = undefined;
        continue;
      }
    }

    const { body, trimmedCaptures } = parseBody(lines);

    snippets.push({
      trigger,
      regexp,
      regexpSource,
      description: m[3] || '',
      body,
      trimmedCaptures: trimmedCaptures.size > 0 ? trimmedCaptures : undefined,
      automatic: flags.includes('A'),
      inword: flags.includes('i'),
      wordboundary: flags.includes('w'),
      beginofline: flags.includes('b'),
      contextFilter: context,
      priority,
    });

    priority = 0;
    context = undefined;
  }

  const kept = disabled.size
    ? snippets.filter(
        (s) => !disabled.has(s.regexpSource ?? s.trigger),
      )
    : snippets;
  return kept.sort((a, b) => b.priority - a.priority);
}
