import katex from 'katex';
import 'katex/dist/katex.min.css';

// KaTeX lacks `\label` and the counter commands, so they throw ParseError and
// kill the whole render. Swallow them with function macros that consume their
// {…} arguments; an empty-string macro would render the arguments as text.
type MacroCtx = { consumeArgs: (n: number) => unknown };
const swallow =
  (n: number) =>
  (ctx: MacroCtx): string => {
    ctx.consumeArgs(n);
    return '';
  };

// KaTeX writes `\gdef` into the `macros` object it is handed, so each render
// gets a fresh copy; a shared one leaks macros across equations and editors.
const KATEX_MACROS = {
  '\\label': swallow(1),
  '\\setcounter': swallow(2),
  '\\addtocounter': swallow(2),
  '\\stepcounter': swallow(1),
  '\\refstepcounter': swallow(1),
};

// Environments KaTeX numbers automatically (starred forms never number).
const NUMBERED_ENV = /\\begin\{(equation|align|gather|alignat)\}/g;
const ROW_SUPPRESSED = /\\notag\b|\\nonumber\b|\\tag\b/;

/**
 * Test instrumentation: counts memo misses. The builders ask for every display
 * region on every rebuild, caret moves included, so the memo matters.
 */
let sourceCountParses = 0;
export function __sourceCountParses(): number {
  return sourceCountParses;
}

const srcCountMemo = new Map<string, number>();

/**
 * Count KaTeX's automatic equation numbers from the SOURCE, without rendering:
 * counting rendered `.eqn-num` would force a KaTeX render of every off-screen
 * region at build time, which stalls first paint. Parity with the rendered
 * count is pinned in katex-cache.test.ts.
 *
 * Rules mirrored from KaTeX: `equation` emits one number unless the body
 * carries `\notag`/`\nonumber`/`\tag`; `align`/`gather`/`alignat` emit one
 * per `\\`-separated row without a suppressor; rows inside nested
 * environments or braces don't count; a trailing empty row is ignored;
 * starred environments emit none.
 */
export function countSourceEquationNumbers(latex: string): number {
  const memoized = srcCountMemo.get(latex);
  if (memoized !== undefined) return memoized;
  sourceCountParses++;
  let total = 0;
  NUMBERED_ENV.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = NUMBERED_ENV.exec(latex)) !== null) {
    const env = m[1];
    const bodyStart = m.index + m[0].length;
    const end = findEnvEnd(latex, bodyStart, env);
    const body = latex.slice(bodyStart, end);
    if (env === 'equation') {
      total += ROW_SUPPRESSED.test(topLevelOnly(body)) ? 0 : 1;
    } else {
      for (const row of splitTopLevelRows(body)) {
        if (ROW_SUPPRESSED.test(row)) continue;
        total += 1;
      }
    }
    NUMBERED_ENV.lastIndex = end;
  }
  // Bounded like the 500-entry render LRUs.
  if (srcCountMemo.size > 1200) srcCountMemo.clear();
  srcCountMemo.set(latex, total);
  return total;
}

/** Index of the matching `\end{env}`, tracking same-name nesting. */
function findEnvEnd(latex: string, from: number, env: string): number {
  const begin = `\\begin{${env}}`;
  const endTok = `\\end{${env}}`;
  let depth = 1;
  let i = from;
  while (i < latex.length) {
    const nextBegin = latex.indexOf(begin, i);
    const nextEnd = latex.indexOf(endTok, i);
    if (nextEnd === -1) return latex.length;
    if (nextBegin !== -1 && nextBegin < nextEnd) {
      depth += 1;
      i = nextBegin + begin.length;
    } else {
      depth -= 1;
      if (depth === 0) return nextEnd;
      i = nextEnd + endTok.length;
    }
  }
  return latex.length;
}

/**
 * Split an align/gather body into rows on `\\` outside nested environments
 * and braces. A trailing blank row is dropped, as KaTeX does.
 */
function splitTopLevelRows(body: string): string[] {
  const rows: string[] = [];
  let braceDepth = 0;
  let envDepth = 0;
  let rowStart = 0;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === '\\') {
      if (body.startsWith('\\begin{', i)) envDepth += 1;
      else if (body.startsWith('\\end{', i)) envDepth -= 1;
      else if (body[i + 1] === '\\' && braceDepth === 0 && envDepth === 0) {
        rows.push(body.slice(rowStart, i));
        rowStart = i + 2;
        i += 1;
        continue;
      } else if (body[i + 1] === '{' || body[i + 1] === '}') {
        i += 1; // escaped brace, not a depth change
        continue;
      }
    } else if (ch === '{') braceDepth += 1;
    else if (ch === '}') braceDepth = Math.max(0, braceDepth - 1);
  }
  rows.push(body.slice(rowStart));
  if (rows.length > 1 && rows[rows.length - 1].trim() === '') rows.pop();
  return rows;
}

/** Body text with nested `\begin…\end` regions blanked (depth-0 view). */
function topLevelOnly(body: string): string {
  return body.replace(/\\begin\{(\w+\*?)\}[\s\S]*?\\end\{\1\}/g, ' ');
}

/**
 * LRU cache of KaTeX render results, keyed by display mode + source. Map
 * insertion order is the LRU order: delete-then-set on every hit.
 */
export class KaTeXCache {
  // null = "fails to render". Failures are cached too, or an invalid region
  // re-runs a full parse-to-throw on every rebuild (caret moves included).
  private cache: Map<string, string | null>;
  private maxSize: number;

  constructor(maxSize = 500) {
    this.cache = new Map();
    this.maxSize = maxSize;
  }

  /** Render LaTeX to HTML, or null on failure so the caller shows raw source. */
  render(latex: string, displayMode: boolean): string | null {
    const key = `${displayMode ? 'D' : 'I'}:${latex}`;

    const cached = this.cache.get(key);
    if (cached !== undefined) {
      this.cache.delete(key);
      this.cache.set(key, cached);
      return cached;
    }

    let html: string | null;
    try {
      html = katex.renderToString(latex, {
        displayMode,
        throwOnError: true,
        macros: { ...KATEX_MACROS },
      });
    } catch (err) {
      // Never rethrow, whatever the error (RangeError from deep nesting,
      // KaTeX-internal TypeErrors): callers run inside a StateField build or
      // toDOM, where a throw blanks the view or bricks dispatch.
      if (!(err instanceof katex.ParseError)) {
        console.error('KaTeX render failed (non-parse error)', err);
      }
      html = null;
    }

    if (this.cache.size >= this.maxSize) {
      const oldest = this.cache.keys().next();
      if (!oldest.done) this.cache.delete(oldest.value);
    }

    this.cache.set(key, html);
    return html;
  }
}
