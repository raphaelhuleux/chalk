/**
 * Parses `.hsnips` files into snippet descriptors.
 *
 * Adapted from draivin/vscode-hsnips `parser.ts` + `hsnippet.ts`.
 * Stripped of VS Code dependencies and the dynamic code generation
 * (new Function / eval). Snippets with inline JS blocks (`\`\`…\`\``)
 * are parsed but the JS is ignored — only the static body is used.
 */

// ── Data types ──────────────────────────────────────────────────────

export interface HSnippet {
  trigger: string;
  regexp?: RegExp;
  description: string;
  body: string;
  automatic: boolean;
  inword: boolean;
  wordboundary: boolean;
  /** Context filter source (e.g. `math(context)`). We evaluate it
   *  with a simple `math` helper rather than arbitrary eval. */
  contextFilter?: string;
  priority: number;
}

// ── Parser ──────────────────────────────────────────────────────────

const HEADER_RE = /^snippet ?(?:`([^`]+)`|(\S+))?(?: "([^"]+)")?(?: ([AMiwb]*))?/;

/**
 * Strips inline JS blocks (``…``) from a snippet body line,
 * keeping the static text around them. For example:
 *   ``rv = m[1]``_{\text{0}}  →  _{\text{0}}
 *   \hat{``rv = m[1]``}       →  \hat{}
 *   ``rv = m[1]``_{``rv = m[2]``}  →  _{}
 */
function stripInlineJs(line: string): string {
  // Replace each ``…`` pair with empty string.
  return line.replace(/``[^`]*``/g, '');
}

function parseBody(lines: string[]): string {
  const out: string[] = [];
  let inCode = false;

  while (lines.length > 0) {
    const line = lines.shift()!;

    if (inCode) {
      // Multi-line JS block — look for closing ``.
      if (line.includes('``')) {
        // Keep text after the closing ``.
        const afterClose = line.split('``').slice(1).join('``');
        if (afterClose) {
          const stripped = stripInlineJs(afterClose);
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

    // Line has `` — could be inline pairs or start of a multi-line block.
    const tickCount = (line.match(/``/g) || []).length;

    if (tickCount % 2 === 0) {
      // Even number of `` — all JS blocks are inline and closed.
      const stripped = stripInlineJs(line);
      out.push(stripped);
    } else {
      // Odd number — last `` opens a multi-line block.
      // Strip all complete pairs, keep text before the unclosed one.
      const parts = line.split('``');
      // Rebuild: static, js, static, js, ..., static (unclosed)
      let result = '';
      for (let i = 0; i < parts.length - 1; i += 2) {
        result += parts[i]; // static part
        // parts[i+1] is JS — skip it
      }
      // Last part starts an unclosed JS block.
      if (result) out.push(result);
      inCode = true;
    }
  }

  return out.join('\n');
}

export function parseHSnips(content: string): HSnippet[] {
  const lines = content.split(/\r?\n/);
  const snippets: HSnippet[] = [];
  let priority = 0;
  let context: string | undefined;
  let inGlobal = false;

  while (lines.length > 0) {
    const line = lines.shift()!;

    if (inGlobal) {
      if (line.startsWith('endglobal')) inGlobal = false;
      continue;
    }

    if (line.startsWith('#')) continue;
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

    if (m[1]) {
      let pat = m[1];
      if (!pat.endsWith('$')) pat += '$';
      regexp = new RegExp(pat, 'm');
      trigger = '';
    }

    const body = parseBody(lines);

    snippets.push({
      trigger,
      regexp,
      description: m[3] || '',
      body,
      automatic: flags.includes('A'),
      inword: flags.includes('i'),
      wordboundary: flags.includes('w'),
      contextFilter: context,
      priority,
    });

    priority = 0;
    context = undefined;
  }

  return snippets.sort((a, b) => b.priority - a.priority);
}
