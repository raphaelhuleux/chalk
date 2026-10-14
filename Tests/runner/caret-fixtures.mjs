#!/usr/bin/env node
/**
 * Fixture harness for caret navigation and mouse selection.
 *
 * One plain-text file per case under Tests/fixtures/caret/. This script
 * enumerates the directory, replays each case against the real editor, and
 * reports the failing file with a diff of expected versus actual.
 *
 *   node Tests/runner/caret-fixtures.mjs            # builds web/dist first
 *   node Tests/runner/caret-fixtures.mjs --no-build # reuse the existing bundle
 *   node Tests/runner/caret-fixtures.mjs --filter wrapped
 *
 * CHALK_BROWSER=webkit selects the engine lane; see
 * Tests/runner/lib/browser.mjs. KNOWN_FAILURES.txt entries may carry a
 * trailing `@tag,tag` list; untagged entries apply to every lane.
 *
 * WHY THIS IS NOT AN XCTEST
 * -------------------------
 * The harness brief asks for one XCTest driving a Swift `ChalkCore`. No such
 * module exists and none can be built at reasonable cost: Chalk's buffer,
 * caret, selection, undo and visual-line mapping are all CodeMirror 6, in
 * TypeScript, inside a WKWebView. Swift never sees a cursor position — the
 * HostPort protocol does not carry one.
 *
 * WHY IT IS NOT VITEST EITHER
 * ---------------------------
 * Every interesting case here is geometric: wrapped visual rows, a goal
 * column carried across short lines, a click at a pixel. CodeMirror answers
 * all three by measuring client rectangles. jsdom implements no layout, and
 * this repo has to stub `Range.getClientRects` to an empty list just to stop
 * the measure cycle from throwing (test/vitest-setup.ts), which makes every
 * coordinate zero. A fixture asserting on wrapped rows in jsdom would be
 * asserting on a fiction.
 *
 * So this drives the BUILT web bundle in headless Chromium with real key and
 * mouse input, the same approach as its sibling Tests/browser/run.mjs, and
 * reads editor state through the `?debug`-gated `window.__chalkDebugView`
 * hook in mount.ts. Headless, deterministic, and pointed at the code that
 * actually owns the caret.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { launchBrowser } from './lib/browser.mjs';
import { loadKnownFailures } from './lib/known-failures.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');
const fixtureRoot = resolve(repoRoot, 'Tests/fixtures');
const knownFailuresFile = resolve(repoRoot, 'Tests/fixtures/KNOWN_FAILURES.txt');

const argv = process.argv.slice(2);
const filterAt = argv.indexOf('--filter');
const filter = filterAt >= 0 ? argv[filterAt + 1] : null;

if (!argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], {
    stdio: 'inherit',
  });
}
if (!existsSync(dist)) {
  console.error(`missing ${dist} — run: pnpm web:build`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
//  Fixture format
// ---------------------------------------------------------------------------
//
//   --- text
//   The quick brown fox jum|ps over the lazy dog
//   --- width
//   20
//   --- keys
//   Down Down Left
//   --- expect
//   The quick brown fox jumps over the la|zy dog
//
// `|` marks an empty caret. `[` and `]` mark a selection range. Sections may
// appear in any order; `text`, `keys` and `expect` are required.
//
// Two optional sections extend the brief's format:
//   --- language   md (default) | tex
//   --- note       free text, ignored by the runner, read by humans
//
// Markers are literal characters, so a marked document cannot contain a
// literal `|`, `[` or `]`. Enforced below rather than left to surprise: a
// case with the wrong marker count fails loudly at parse time.
//
// Documents that NEED those characters (a GFM table's pipes, tex `\[ \]`
// display math, `\includegraphics[...]`) use the numeric alternative: an
//   --- caret        section (one offset, or two for a range) alongside a
// marker-free `text`, and/or an
//   --- expect-caret section alongside a marker-free `expect`. The offsets
// index the section's raw document text. Mixing a marker and the numeric
// section for the same document is an error.

/** Split a fixture file into its `--- name` sections. */
function parseSections(src, file) {
  const sections = Object.create(null);
  let current = null;
  for (const line of src.split('\n')) {
    const header = /^---[ \t]+([A-Za-z][A-Za-z0-9_-]*)[ \t]*$/.exec(line);
    if (header) {
      current = header[1];
      if (current in sections) throw new Error(`${file}: duplicate section "${current}"`);
      sections[current] = [];
      continue;
    }
    if (current === null) {
      if (line.trim() === '') continue;
      throw new Error(`${file}: content before the first "--- section" header: ${JSON.stringify(line)}`);
    }
    sections[current].push(line);
  }
  // Drop trailing blank lines from every section: they are an artifact of the
  // next header sitting on its own line, not part of the document.
  for (const key of Object.keys(sections)) {
    const lines = sections[key];
    while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  }
  return sections;
}

/**
 * Strip the caret/selection markers out of `marked`, returning the bare
 * document text and the offsets the markers stood at.
 */
function extractMarkers(marked, file, label) {
  const carets = (marked.match(/\|/g) ?? []).length;
  const opens = (marked.match(/\[/g) ?? []).length;
  const closes = (marked.match(/\]/g) ?? []).length;

  if (carets === 1 && opens === 0 && closes === 0) {
    const at = marked.indexOf('|');
    return { doc: marked.slice(0, at) + marked.slice(at + 1), from: at, to: at };
  }
  if (carets === 0 && opens === 1 && closes === 1) {
    const open = marked.indexOf('[');
    const close = marked.indexOf(']');
    if (close < open) throw new Error(`${file}: ${label} has "]" before "["`);
    const doc = marked.slice(0, open) + marked.slice(open + 1, close) + marked.slice(close + 1);
    return { doc, from: open, to: close - 1 };
  }
  throw new Error(
    `${file}: ${label} must carry exactly one "|", or exactly one "[" and one "]" ` +
      `(found ${carets} caret, ${opens} open, ${closes} close). ` +
      `Literal | [ ] characters in fixture text are not supported.`,
  );
}

/** Numeric alternative to inline markers, for documents that must contain
 *  literal `|` `[` `]` (GFM tables, tex display math): the section body is
 *  the untouched document and the caret comes from `--- caret` /
 *  `--- expect-caret` — "34" for an empty caret, "12 20" for a range. */
function atMarkers(doc, spec, file, label) {
  const nums = spec.trim().split(/\s+/).filter(Boolean).map(Number);
  if (
    nums.length < 1 ||
    nums.length > 2 ||
    nums.some((n) => !Number.isInteger(n) || n < 0 || n > doc.length)
  ) {
    throw new Error(
      `${file}: "${label}" must be one or two integer offsets within the document, ` +
        `got ${JSON.stringify(spec.trim())}`,
    );
  }
  const [from, to = from] = nums;
  if (to < from) throw new Error(`${file}: "${label}" range is reversed`);
  return { doc, from, to };
}

/** Re-insert markers into `doc` so actual output can be diffed against expect. */
function renderMarkers(doc, from, to) {
  if (from === to) return doc.slice(0, from) + '|' + doc.slice(from);
  return doc.slice(0, from) + '[' + doc.slice(from, to) + ']' + doc.slice(to);
}

function loadFixture(file) {
  const src = readFileSync(file, 'utf8');
  const name = relative(repoRoot, file);
  const sections = parseSections(src, name);

  for (const required of ['text', 'keys', 'expect']) {
    if (!(required in sections)) throw new Error(`${name}: missing "--- ${required}" section`);
  }

  const start =
    'caret' in sections
      ? atMarkers(sections.text.join('\n'), sections.caret.join(' '), name, 'caret')
      : extractMarkers(sections.text.join('\n'), name, 'the "text" section');
  const expect =
    'expect-caret' in sections
      ? atMarkers(sections.expect.join('\n'), sections['expect-caret'].join(' '), name, 'expect-caret')
      : extractMarkers(sections.expect.join('\n'), name, 'the "expect" section');

  let width = null;
  if ('width' in sections) {
    const raw = sections.width.join('').trim();
    width = Number(raw);
    if (!Number.isInteger(width) || width < 1) {
      throw new Error(`${name}: "width" must be a positive integer, got ${JSON.stringify(raw)}`);
    }
  }

  const language = 'language' in sections ? sections.language.join('').trim() : 'md';
  if (language !== 'md' && language !== 'tex') {
    throw new Error(`${name}: "language" must be md or tex, got ${JSON.stringify(language)}`);
  }

  const keys = sections.keys.join(' ').trim().split(/\s+/).filter(Boolean);
  if (!keys.length) throw new Error(`${name}: "keys" section is empty`);

  // Navigation must never mutate the document, and the runner says so when it
  // does. Editing keys make that warning meaningless, so it is suppressed only
  // for cases that actually carry one.
  const EDITING = /^(Type\(|Backspace$|Delete$|Enter$|Tab$)|^(Cmd|Meta)\+(Z|V|X|Y)$|^(Cmd|Meta)\+Shift\+Z$/;
  const edits = keys.some((k) => EDITING.test(k));

  return { name, file, start, expect, width, language, keys, edits };
}

// ---------------------------------------------------------------------------
//  In-page probes
// ---------------------------------------------------------------------------

/** Selection as offsets, plus the document text (to catch accidental edits). */
const READ_STATE = () => {
  const v = window.__chalkDebugView;
  const sel = v.state.selection.main;
  return { doc: v.state.doc.toString(), from: sel.from, to: sel.to };
};

/**
 * Font metrics of the writing surface. `charWidth` is measured over a 100
 * character run so sub-pixel advance does not round away, and `iWidth` /
 * `wWidth` exist only so the caller can refuse to run on a proportional font
 * (every column in this harness assumes a fixed advance).
 */
const READ_METRICS = () => {
  const view = window.__chalkDebugView;
  const content = document.querySelector('.cm-content');
  const line = document.querySelector('.cm-line');
  const probe = document.createElement('span');
  const cs = getComputedStyle(content);
  probe.style.cssText =
    `position:absolute;visibility:hidden;white-space:pre;` +
    `font:${cs.font};font-family:${cs.fontFamily};font-size:${cs.fontSize};` +
    `font-variant-ligatures:none;letter-spacing:${cs.letterSpacing}`;
  document.body.appendChild(probe);
  const advance = (s, n) => {
    probe.textContent = s.repeat(n);
    return probe.getBoundingClientRect().width / n;
  };
  const charWidth = advance('x', 100);
  const iWidth = advance('i', 100);
  const wWidth = advance('W', 100);
  probe.remove();
  const lineStyle = getComputedStyle(line);
  return {
    charWidth,
    iWidth,
    wWidth,
    linePadLeft: parseFloat(lineStyle.paddingLeft) || 0,
    linePadRight: parseFloat(lineStyle.paddingRight) || 0,
    lineHeight: view.defaultLineHeight,
  };
};

/** Viewport point of the first character, the origin every click is measured from. */
const READ_ORIGIN = () => {
  const c = window.__chalkDebugView.coordsAtPos(0);
  return c ? { left: c.left, top: c.top } : null;
};

// ---------------------------------------------------------------------------
//  Key replay
// ---------------------------------------------------------------------------

const PLAIN_KEYS = {
  Up: 'ArrowUp',
  Down: 'ArrowDown',
  Left: 'ArrowLeft',
  Right: 'ArrowRight',
  Home: 'Home',
  End: 'End',
  // Beyond the brief's navigation set, so areas like undo and redo are
  // expressible as fixtures rather than merely described in prose.
  Backspace: 'Backspace',
  Delete: 'Delete',
  Enter: 'Enter',
  Tab: 'Tab',
  Escape: 'Escape',
  Space: ' ',
  PageUp: 'PageUp',
  PageDown: 'PageDown',
};

// Single letters and digits, so Cmd+Z, Cmd+Shift+Z, Cmd+C and friends work.
for (const ch of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') PLAIN_KEYS[ch] = ch;

const MODIFIERS = { Cmd: 'Meta', Meta: 'Meta', Alt: 'Alt', Opt: 'Alt', Shift: 'Shift', Ctrl: 'Control' };

/** "Shift+Cmd+Left" -> "Shift+Meta+ArrowLeft", the form Playwright expects. */
function toPlaywrightKey(token, fixtureName) {
  const parts = token.split('+');
  const base = parts.pop();
  const key = PLAIN_KEYS[base];
  if (!key) throw new Error(`${fixtureName}: unknown key "${token}"`);
  const mods = parts.map((m) => {
    const mapped = MODIFIERS[m];
    if (!mapped) throw new Error(`${fixtureName}: unknown modifier "${m}" in "${token}"`);
    return mapped;
  });
  return [...mods, key].join('+');
}

const CLICK_RE = /^(Click|DoubleClick|TripleClick)\((\d+),\s*(\d+)\)$/;
// Type(hello) inserts literal text. Keys are space separated, so the argument
// cannot contain a space: use the Space key for that.
const TYPE_RE = /^Type\(([^)]*)\)$/;

/**
 * Pixel point for Click(row, col).
 *
 * `row` is the 1-based VISUAL row counted from the top of the document, so a
 * wrapped line contributes one row per rendered row. `col` is the 0-based
 * column within that row. Both are what the user sees, which is the only
 * reading that makes a click fixture mean anything.
 *
 * A single Click aims a quarter of a character into the target column, so the
 * nearest character boundary — where CodeMirror puts the caret — is the one
 * at `col`. The multi-click forms aim at the middle of the character instead,
 * because they need to land INSIDE a word rather than beside it.
 */
function clickPoint(kind, row, col, origin, metrics) {
  const bias = kind === 'Click' ? 0.25 : 0.5;
  return {
    x: origin.left + (col + bias) * metrics.charWidth,
    y: origin.top + (row - 1 + 0.5) * metrics.lineHeight,
  };
}

async function applyKeys(page, fixture, origin, metrics) {
  for (const token of fixture.keys) {
    const typed = TYPE_RE.exec(token);
    if (typed) {
      await page.keyboard.type(typed[1]);
      await page.waitForTimeout(30);
      continue;
    }
    const click = CLICK_RE.exec(token);
    if (click) {
      const [, kind, row, col] = click;
      const { x, y } = clickPoint(kind, Number(row), Number(col), origin, metrics);
      const count = kind === 'Click' ? 1 : kind === 'DoubleClick' ? 2 : 3;
      await page.mouse.click(x, y, { clickCount: count });
      // Multi-click selection is applied on the click that completes it; the
      // wait keeps the next assertion off a half-applied selection.
      await page.waitForTimeout(60);
      continue;
    }
    await page.keyboard.press(toPlaywrightKey(token, fixture.name));
    await page.waitForTimeout(25);
  }
}

// ---------------------------------------------------------------------------
//  Case runner
// ---------------------------------------------------------------------------

async function runCase(browser, fixture) {
  // The viewport stays the harness's own so fixture geometry is identical
  // across lanes.
  const page = await browser.newPage({ ...contextOptions, viewport: { width: 900, height: 900 } });
  const pageErrors = [];
  page.on('pageerror', (e) => pageErrors.push(String(e)));
  try {
    await page.goto(pathToFileURL(dist).href + '?debug');
    await page.waitForFunction('() => window.__chalkHost !== undefined');
    await page.evaluate((msg) => window.__chalkHost.receive(msg), {
      type: 'init',
      text: fixture.start.doc,
      language: fixture.language,
    });
    await page.waitForSelector('.cm-content');
    await page.waitForTimeout(250);

    const metrics = await page.evaluate(READ_METRICS);
    if (Math.abs(metrics.iWidth - metrics.wWidth) > 0.01) {
      throw new Error(
        `the writing surface is not monospaced in this browser ` +
          `(i=${metrics.iWidth.toFixed(2)}px, W=${metrics.wWidth.toFixed(2)}px); ` +
          `every column in this harness assumes a fixed advance`,
      );
    }

    if (fixture.width !== null) {
      // Wrap at exactly `width` characters. The text column is the content
      // box (chalk-theme.css deliberately keeps horizontal padding off
      // .cm-content), but CodeMirror's own theme pads .cm-line, so that pair
      // has to be added back. The half pixel absorbs sub-pixel rounding that
      // would otherwise wrap one character early.
      const px =
        fixture.width * metrics.charWidth + metrics.linePadLeft + metrics.linePadRight + 0.5;
      await page.addStyleTag({
        content: `.editor-host .cm-content { max-width: ${px}px !important; width: ${px}px !important; }`,
      });
      await page.evaluate(() => window.__chalkDebugView.requestMeasure());
      await page.waitForTimeout(200);
    }

    await page.evaluate(
      ([from, to]) => {
        const v = window.__chalkDebugView;
        v.dispatch({ selection: { anchor: from, head: to } });
        v.focus();
      },
      [fixture.start.from, fixture.start.to],
    );
    await page.waitForTimeout(60);

    const origin = await page.evaluate(READ_ORIGIN);
    if (!origin) throw new Error('could not locate the first character; the document may be empty');

    await applyKeys(page, fixture, origin, metrics);
    await page.waitForTimeout(60);

    const state = await page.evaluate(READ_STATE);
    if (pageErrors.length) throw new Error(`page error: ${pageErrors[0]}`);

    const actual = renderMarkers(state.doc, state.from, state.to);
    const expected = renderMarkers(fixture.expect.doc, fixture.expect.from, fixture.expect.to);
    return { pass: actual === expected, actual, expected, docChanged: state.doc !== fixture.start.doc };
  } finally {
    await page.close();
  }
}

// ---------------------------------------------------------------------------
//  Reporting
// ---------------------------------------------------------------------------

/**
 * Diff two marked documents line by line. Output is meant to be read by a
 * person or by another agent, so it names the file, the line, and the column
 * of the first difference rather than dumping two blobs.
 */
function formatDiff(expected, actual) {
  const e = expected.split('\n');
  const a = actual.split('\n');
  const out = [];
  for (let i = 0; i < Math.max(e.length, a.length); i++) {
    const el = e[i] ?? '<no line>';
    const al = a[i] ?? '<no line>';
    if (el === al) {
      out.push(`      ${i + 1} | ${el}`);
      continue;
    }
    let col = 0;
    while (col < el.length && col < al.length && el[col] === al[col]) col++;
    out.push(`  exp ${i + 1} | ${el}`);
    out.push(`  got ${i + 1} | ${al}`);
    out.push(`        | ${' '.repeat(col)}^ first difference at column ${col}`);
  }
  return out.join('\n');
}

// ---------------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------------

if (!existsSync(fixtureRoot)) {
  console.error(`missing fixture directory ${fixtureRoot}`);
  process.exit(1);
}

// One directory per area, so "the area with the fewest fixtures" is a fact
// on disk rather than a claim in a document.
let files = [];
for (const area of readdirSync(fixtureRoot, { withFileTypes: true })) {
  if (!area.isDirectory()) continue;
  const dir = join(fixtureRoot, area.name);
  for (const f of readdirSync(dir).sort()) {
    if (f.endsWith('.txt')) files.push(join(dir, f));
  }
}
files.sort();
if (filter) files = files.filter((f) => f.includes(filter));

if (!files.length) {
  console.error(`no fixtures matched${filter ? ` --filter ${filter}` : ''} in ${fixtureDir}`);
  process.exit(1);
}

const known = loadKnownFailures(knownFailuresFile, 'Tests/fixtures/KNOWN_FAILURES.txt');
const { browser, contextOptions, tag } = await launchBrowser();
const unexpectedFailures = [];
const knownFailures = [];
const unexpectedPasses = [];
let passed = 0;

console.log(`caret fixtures: ${files.length} case${files.length === 1 ? '' : 's'}\n`);

for (const file of files) {
  const short = relative(repoRoot, file);
  let fixture;
  try {
    fixture = loadFixture(file);
  } catch (e) {
    console.log(`FAIL ${short}\n  ${e.message}\n`);
    unexpectedFailures.push({ name: short, reason: e.message });
    continue;
  }

  let result;
  try {
    result = await runCase(browser, fixture);
  } catch (e) {
    console.log(`FAIL ${short}\n  harness error: ${e.message}\n`);
    unexpectedFailures.push({ name: short, reason: `harness error: ${e.message}` });
    continue;
  }

  const isKnown = known.isKnown(short, tag);
  if (result.pass) {
    if (isKnown) {
      console.log(`PASS ${short}  (${known.formatUnexpectedPass(short, tag)})`);
      unexpectedPasses.push(short);
    } else {
      console.log(`ok   ${short}`);
    }
    passed++;
    continue;
  }

  const label = isKnown ? 'known' : 'FAIL';
  console.log(`${label} ${short}`);
  console.log(`  keys: ${fixture.keys.join(' ')}${fixture.width ? `   width: ${fixture.width}` : ''}`);
  if (result.docChanged && !fixture.edits) {
    console.log('  WARNING: the document text changed, but no key in this case should edit');
  }
  console.log(formatDiff(result.expected, result.actual));
  console.log('');
  (isKnown ? knownFailures : unexpectedFailures).push({ name: short, reason: 'expectation mismatch' });
}

await browser.close();

console.log(
  `\n[${tag}] ${passed} passed, ${unexpectedFailures.length} failed` +
    `, ${knownFailures.length} known-failing` +
    (unexpectedPasses.length ? `, ${unexpectedPasses.length} newly passing` : ''),
);

if (unexpectedPasses.length) {
  console.log(
    `\nThese are listed in Tests/fixtures/KNOWN_FAILURES.txt but now pass. ` +
      `Delete their lines:\n  ${unexpectedPasses.join('\n  ')}`,
  );
}

process.exit(unexpectedFailures.length ? 1 : 0);
