#!/usr/bin/env node
/**
 * Browser regression harness for caret navigation and pointer interaction
 * over previewed LaTeX constructs.
 *
 * jsdom cannot express the behaviors that actually regress here — wrapped
 * visual rows, pixel goal columns, click coordinates, reveal-driven reflow —
 * so this drives the BUILT web bundle (web/dist) in headless Chromium with
 * real mouse/keyboard input, and reads editor state through the
 * `?debug`-gated `window.__chalkDebugView` hook (mount.ts).
 *
 * Run from the repo root:
 *   pnpm test:browser            # builds web/dist first
 *   pnpm test:browser --no-build # reuse the existing bundle
 *   pnpm test:browser:webkit     # same scenarios, headless WebKit
 *   pnpm test:browser --only drag  # just the scenarios whose name contains "drag"
 *
 * Lanes are selected by CHALK_BROWSER (see
 * Tests/runner/lib/browser.mjs). Engine-behavior differences are recorded in
 * KNOWN_FAILURES.txt next to this file, one `scenario :: check [@tag]` line
 * each: a listed check that fails prints `xfail` and does not fail the run;
 * a listed check that passes prints XPASS and DOES fail it, so stale entries
 * cannot linger.
 *
 * Contracts pinned (each maps to a fixed bug — see the pointer-gesture and
 * tex-vertical-motion module headers for the mechanisms):
 *   - clicks land exactly, geometry frozen while the button is down
 *   - double-click selects the word the user saw (conceal-override undo)
 *   - pills/formulas have no dead zones and open on release
 *   - Up/Down passes over rendered constructs and keeps the goal column
 *   - wrapped lines are walked row by row before document-line stops fire
 *   - a reveal never leaves sibling widgets painted at stale offsets
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { inflateSync } from 'node:zlib';
import { launchBrowser } from '../runner/lib/browser.mjs';
import { loadKnownFailures } from '../runner/lib/known-failures.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');
const onlyAt = process.argv.indexOf('--only');
const only = onlyAt >= 0 ? process.argv[onlyAt + 1] : null;

const kf = loadKnownFailures(
  resolve(repoRoot, 'Tests/browser/KNOWN_FAILURES.txt'),
  'Tests/browser/KNOWN_FAILURES.txt',
);

if (!process.argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], {
    stdio: 'inherit',
  });
}
if (!existsSync(dist)) {
  console.error(`missing ${dist} — run: pnpm web:build`);
  process.exit(1);
}

const STATE = () => {
  const v = window.__chalkDebugView;
  const head = v.state.selection.main.head;
  const line = v.state.doc.lineAt(head);
  const c = v.coordsAtPos(head);
  return { head, line: line.number, col: head - line.from,
           x: c ? Math.round(c.left) : null,
           empty: v.state.selection.main.empty };
};

const SEL_TEXT = () => {
  const v = window.__chalkDebugView;
  const m = v.state.selection.main;
  return v.state.sliceDoc(m.from, m.to);
};

/** Viewport rect of `needle`'s first occurrence in rendered text. */
const FIND_TEXT = (needle) => {
  const walker = document.createTreeWalker(document.querySelector('.cm-content'), NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const n = walker.currentNode;
    const i = n.textContent.indexOf(needle);
    if (i >= 0) {
      const r = document.createRange();
      r.setStart(n, i); r.setEnd(n, i + needle.length);
      const b = r.getBoundingClientRect();
      return { x: b.x, y: b.y, w: b.width, h: b.height };
    }
  }
  return null;
};

/** Viewport rect of the first element matching `sel` (a rendered widget). */
const FIND_CSS = (sel) => {
  const e = document.querySelector(sel);
  if (!e) return null;
  const b = e.getBoundingClientRect();
  return { x: b.x, y: b.y, w: b.width, h: b.height };
};

let failures = 0;
let xfails = 0;
function check(scenario, name, ok, detail = '') {
  if (kf.isKnown(`${scenario} :: ${name}`, tag)) {
    if (ok) {
      // A listed check that passes must fail the run, or fixed entries rot.
      console.log(`  XPASS ${name}  (${kf.formatUnexpectedPass(`${scenario} :: ${name}`, tag)})`);
      failures++;
    } else {
      console.log(`  xfail ${name}${detail ? `  (${detail})` : ''}`);
      xfails++;
    }
    return;
  }
  const mark = ok ? 'ok  ' : 'FAIL';
  console.log(`  ${mark} ${name}${ok || !detail ? '' : `  (${detail})`}`);
  if (!ok) failures++;
}

async function scenario(
  browser,
  name,
  doc,
  fn,
  viewport = { width: 760, height: 900 },
  language = 'tex',
  init = null,
  editorConfig = null,
) {
  if (only && !name.includes(only)) return;
  console.log(`\n${name}`);
  // Each scenario keeps its own viewport so geometry is identical across lanes.
  const page = await browser.newPage({ ...contextOptions, viewport });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  // CM6 catches a throw from a decoration builder, logs it and DISABLES the
  // plugin — no page error, and the document quietly falls back to raw
  // source. A geometry check then measures an editor that renders nothing it
  // is asking about and passes for the wrong reason, which is how a broken
  // `cm-math-glue` once read as a fix. So console errors fail the scenario.
  page.on('console', (m) => {
    if (m.type() === 'error') errors.push(`console: ${m.text()}`);
  });
  // Runs before any page script: the only way to stand in for the native
  // bridge, which native-host.ts binds at module scope on boot.
  if (init) await page.addInitScript(init);
  await page.goto(pathToFileURL(dist).href + '?debug');
  await page.waitForFunction('() => window.__chalkHost !== undefined');
  await page.evaluate((msg) => window.__chalkHost.receive(msg), {
    type: 'init',
    text: doc,
    language,
    ...(editorConfig ? { editorConfig } : {}),
  });
  await page.waitForSelector('.cm-content');
  await page.waitForTimeout(400);
  await fn(page, (n, ok, d) => check(name, n, ok, d));
  check(name, 'no page or console errors', errors.length === 0, errors[0]);
  await page.close();
}

const content = (page) => page.innerText('.cm-content');
const setCursor = (page, pos) =>
  page.evaluate((p) => {
    const v = window.__chalkDebugView;
    v.dispatch({ selection: { anchor: p } });
    v.focus();
  }, pos);

const { browser, contextOptions, tag } = await launchBrowser();

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'click precision + reveal on release',
  'aaaa aaaa aaaa\nThis is \\textbf{standard} prose here.\npark line for the caret\n',
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'standard');
    // Press mid-word and HOLD: geometry must not change while down.
    await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
    await page.mouse.down();
    await page.waitForTimeout(80);
    ok('still concealed while pressed', !(await content(page)).includes('\\textbf{'));
    await page.mouse.up();
    await page.waitForTimeout(80);
    const st = await page.evaluate(STATE);
    ok('revealed on release', (await content(page)).includes('\\textbf{standard}'));
    ok('caret is an empty cursor', st.empty);
    ok('caret inside the word', st.line === 2);
  },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'micro-drift press: no flicker, no phantom selection',
  '\\section{Model}\ntext\n\\subsection{Households and firms}\nmore text here\npark line\n',
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'Households');
    await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
    await page.mouse.down();
    let flips = 0;
    let last = null;
    for (const dx of [1, 2, 3, 4]) {
      await page.mouse.move(r.x + r.w / 2 + dx, r.y + r.h / 2 + (dx % 2));
      await page.waitForTimeout(40);
      const revealed = (await content(page)).includes('\\subsection{');
      if (last !== null && revealed !== last) flips++;
      last = revealed;
    }
    await page.mouse.up();
    await page.waitForTimeout(80);
    ok('zero conceal/reveal flips mid-press', flips === 0, `flips=${flips}`);
    ok('empty selection after the press', (await page.evaluate(STATE)).empty);
    ok('revealed after release', (await content(page)).includes('\\subsection{'));
  },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'keyboard motion during a held press resyncs the frozen set',
  'aaaa aaaa aaaa\nThis is \\textbf{standard} prose here.\npark line for the caret\n',
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'standard');
    await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
    await page.mouse.down();
    await page.waitForTimeout(80);
    ok('still concealed while pressed', !(await content(page)).includes('\\textbf{'));
    // Keyboard ends the gesture semantics: the frozen (stale) decorations
    // must rebuild on this selection change, not wait for mouseup — pinned
    // in jsdom by caret-rebuild.test.ts, and here against real geometry.
    await page.keyboard.press('ArrowLeft');
    await page.waitForTimeout(80);
    ok('revealed by keyboard motion mid-press', (await content(page)).includes('\\textbf{standard}'));
    await page.mouse.up();
    await page.waitForTimeout(80);
    ok('still revealed after release', (await content(page)).includes('\\textbf{standard}'));
  },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'double-click selects the word the user saw',
  'The result is \\textbf{standard} in the literature.\npark line\n',
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'standard');
    await page.mouse.dblclick(r.x + r.w / 2, r.y + r.h / 2);
    await page.waitForTimeout(150);
    const sel = await page.evaluate(SEL_TEXT);
    ok('selection is the aimed word', sel === 'standard', `got ${JSON.stringify(sel)}`);
    ok('construct stays concealed', !(await content(page)).includes('\\textbf{'));
  },
);

// ---------------------------------------------------------------------------
//  Markdown twins of the four pointer scenarios above.
//
//  Freezing the reveal while the button is down and undoing it for a
//  double-click are language-independent contracts: a mousedown that reveals
//  reflows md live-preview exactly the way it reflows tex conceal. The tracker
//  was registered only in the tex branch, so md had none of it — these lanes
//  are the fence that keeps it registered for both languages.
// ---------------------------------------------------------------------------
const MD_POINTER_DOC =
  'aaaa filler line one\n' +
  'This is **bold** prose with inline $a+b$ math in it.\n' +
  '$$\n' +
  'E = mc^2\n' +
  '$$\n' +
  '::: {#thm-one}\n' +
  'inner theorem line\n' +
  ':::\n' +
  'park line for the caret\n';

// A bold span with a long argument: the drift and double-click lanes need a
// wide, easy-to-aim word whose construct actually hides something (markdown
// headings keep their `##` on screen, so they reveal nothing to freeze).
const MD_BOLD_DOC =
  'Model notes line\ntext here\nThe **Households and firms** block sits here.\n' +
  'more text here\npark line\n';

await scenario(
  browser,
  'md click precision + reveal on release',
  MD_POINTER_DOC,
  async (page, ok) => {
    // `find` is ['text', needle] for rendered prose, ['css', selector] for a
    // replaced widget; `source` is the raw text that must be hidden while the
    // button is down and back on screen after the release.
    const constructs = [
      { name: 'bold', find: ['text', 'bold'], source: '**bold**' },
      { name: 'inline math', find: ['css', '.cm-math-inline'], source: '$a+b$' },
      { name: 'display math', find: ['css', '.cm-math-display'], source: 'E = mc^2' },
      { name: 'theorem open fence', find: ['css', '.cm-callout-label'], source: '::: {#thm-one}' },
    ];
    for (const c of constructs) {
      await setCursor(page, 0);
      await page.waitForTimeout(150);
      const [how, what] = c.find;
      const r = await page.evaluate(how === 'text' ? FIND_TEXT : FIND_CSS, what);
      ok(`${c.name}: found the click target`, r !== null, what);
      if (!r) continue;
      await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
      await page.mouse.down();
      await page.waitForTimeout(100);
      ok(`${c.name}: still concealed while pressed`, !(await content(page)).includes(c.source));
      await page.mouse.up();
      await page.waitForTimeout(120);
      ok(`${c.name}: revealed on release`, (await content(page)).includes(c.source));
      ok(`${c.name}: caret is an empty cursor`, (await page.evaluate(STATE)).empty);
    }
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'md micro-drift press: no flicker, no phantom selection',
  MD_BOLD_DOC,
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'Households');
    await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
    await page.mouse.down();
    let flips = 0;
    let last = null;
    let everRevealed = false;
    for (const dx of [1, 2, 3, 4]) {
      await page.mouse.move(r.x + r.w / 2 + dx, r.y + r.h / 2 + (dx % 2));
      await page.waitForTimeout(40);
      const revealed = (await content(page)).includes('**Households');
      if (revealed) everRevealed = true;
      if (last !== null && revealed !== last) flips++;
      last = revealed;
    }
    await page.mouse.up();
    await page.waitForTimeout(120);
    ok('the construct stays concealed for the whole press', !everRevealed);
    ok('zero conceal/reveal flips mid-press', flips === 0, `flips=${flips}`);
    ok('empty selection after the press', (await page.evaluate(STATE)).empty);
    ok('revealed after release', (await content(page)).includes('**Households'));
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'md keyboard motion during a held press resyncs the frozen set',
  MD_POINTER_DOC,
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'bold');
    await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
    await page.mouse.down();
    await page.waitForTimeout(100);
    ok('still concealed while pressed', !(await content(page)).includes('**bold**'));
    await page.keyboard.press('ArrowLeft');
    await page.waitForTimeout(100);
    ok('revealed by keyboard motion mid-press', (await content(page)).includes('**bold**'));
    await page.mouse.up();
    await page.waitForTimeout(100);
    ok('still revealed after release', (await content(page)).includes('**bold**'));
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'md double-click selects the word the user saw',
  MD_BOLD_DOC,
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'Households');
    await page.mouse.dblclick(r.x + r.w / 2, r.y + r.h / 2);
    await page.waitForTimeout(150);
    const sel = await page.evaluate(SEL_TEXT);
    ok('selection is the aimed word', sel === 'Households', `got ${JSON.stringify(sel)}`);
    ok('construct stays concealed', !(await content(page)).includes('**Households'));
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
//  A collapsed `:::` close fence has no visual row of its own, so no pointer
//  can land on it: what it pins is the OTHER half of the gate — a press inside
//  the callout body must not reveal it, and the Down-arrow fence stop must
//  still get through while that press is held (the frozen set resyncs on
//  keyboard motion instead of waiting for the release).
await scenario(
  browser,
  'md callout close fence under a held press',
  MD_POINTER_DOC,
  async (page, ok) => {
    await setCursor(page, 0);
    const r = await page.evaluate(FIND_TEXT, 'inner theorem');
    await page.mouse.move(r.x + r.w / 2, r.y + r.h / 2);
    await page.mouse.down();
    await page.waitForTimeout(100);
    ok('close fence stays collapsed while the body row is pressed',
       !(await content(page)).includes(':::'));
    await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(120);
    ok('Down mid-press reveals the close fence', (await content(page)).includes(':::'));
    await page.mouse.up();
    await page.waitForTimeout(100);
    ok('still revealed after release', (await content(page)).includes(':::'));
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'pill and formula dead zones',
  'see \\ref{fig:model} and the map $X \\in \\mathbb{R}^{n}$ here\npark line\n',
  async (page, ok) => {
    for (const [cls, marker, side] of [
      ['.cm-tex-ref-pill', '\\ref{', 'left'],
      ['.cm-tex-ref-pill', '\\ref{', 'right'],
      ['.cm-tex-math-inline', '$X \\in', 'right'],
    ]) {
      await setCursor(page, 0);
      await page.waitForTimeout(60);
      const b = await page.locator(cls).first().boundingBox();
      const x = side === 'left' ? b.x + 2 : b.x + b.width - 2;
      await page.mouse.click(x, b.y + b.height / 2);
      await page.waitForTimeout(120);
      ok(`${cls} ${side}-half click reveals`, (await content(page)).includes(marker));
    }
    // Pill click parks the caret on the key.
    await setCursor(page, 0);
    await page.waitForTimeout(60);
    const b = await page.locator(".cm-tex-ref-pill").first().boundingBox();
    await page.mouse.click(b.x + b.width - 2, b.y + b.height / 2);
    await page.waitForTimeout(120);
    const st = await page.evaluate(STATE);
    const keyPos = await page.evaluate(
      () => window.__chalkDebugView.state.doc.toString().indexOf('fig:model'),
    );
    ok('caret parked on the key', st.head === keyPos, `head=${st.head} key=${keyPos}`);
  },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'vertical transit: no reveals, exact column return',
  'aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa\n' +
    'bbbb $X \\in \\mathbb{R}^{n \\times k}$ bbbb $a+b$ bbbb\n' +
    'cccc cccc cccc cccc cccc cccc cccc cccc\n' +
    'dddd \\ref{fig:model} dddd \\emph{word} dddd\n' +
    'eeee eeee eeee eeee eeee eeee eeee eeee\n' +
    '\\begin{theorem}\nffff $c+d$ ffff\n\\end{theorem}\n' +
    'gggg gggg gggg gggg gggg gggg gggg gggg\n',
  async (page, ok) => {
    await setCursor(page, 18);
    await page.waitForTimeout(100);
    const start = await page.evaluate(STATE);
    let transitReveals = 0;
    for (let i = 0; i < 8; i++) {
      await page.keyboard.press('ArrowDown');
      await page.waitForTimeout(70);
      const t = await content(page);
      for (const m of ['$X \\in', '$a+b$', '\\ref{', '\\emph{', '$c+d$']) {
        if (t.includes(m)) transitReveals++;
      }
    }
    const end = await page.evaluate(STATE);
    ok('no inline constructs revealed in transit', transitReveals === 0, `count=${transitReveals}`);
    ok('landed on the last text line', end.line === 9, `line=${end.line}`);
    ok('goal column returned exactly', end.x === start.x, `start=${start.x} end=${end.x}`);
  },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'wrapped line walks its rows before a display-math stop',
  '$y \\in \\mathbb{R}^n$ and a matrix $X \\in \\mathbb{R}^{n \\times k}$ ' +
    'whose columns are the regressors. Throughout, $k < n$ and $X$ has ' +
    '\\textbf{full column rank}, so $X^\\top X$ is invertible. The model is\n' +
    '\\begin{equation}\n    y = X\\beta .\n\\end{equation}\nafter text\n',
  async (page, ok) => {
    await setCursor(page, 25); // first visual row of the wrapped paragraph
    await page.waitForTimeout(100);
    const lines = [];
    for (let i = 0; i < 3; i++) {
      await page.keyboard.press('ArrowDown');
      await page.waitForTimeout(70);
      lines.push((await page.evaluate(STATE)).line);
    }
    ok('presses 1-2 stay in the wrapped line', lines[0] === 1 && lines[1] === 1, `lines=${lines}`);
    ok('press 3 reaches the equation line', lines[2] === 2, `lines=${lines}`);
  },
  { width: 700, height: 900 },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'reveal reflow leaves no stale widget paint (layout integrity)',
  'We observe $n$ pairs and stack them into $y \\in \\mathbb{R}^n$ and a ' +
    'matrix $X \\in \\mathbb{R}^{n \\times k}$ whose columns are the ' +
    'regressors. Throughout, $k < n$ and $X$ has full \\textbf{column rank}, ' +
    'so $X^\\top X$ is invertible.\npark line\n',
  async (page, ok) => {
    await setCursor(page, 0);
    await page.waitForTimeout(60);
    // Reveal the widest math mid-line, then scan for widget/text overlaps.
    const widgets = page.locator('.cm-tex-math-inline');
    const b = await widgets.nth(2).boundingBox();
    await page.mouse.click(b.x + 3, b.y + b.height / 2);
    await page.waitForTimeout(200);
    const overlaps = await page.evaluate(() => {
      const content = document.querySelector('.cm-content');
      const rects = [];
      for (const w of content.querySelectorAll('.cm-tex-math-inline')) {
        const b = w.getBoundingClientRect();
        rects.push({ kind: 'widget', x: b.x, y: b.y, w: b.width, h: b.height });
      }
      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const n = walker.currentNode;
        if (!n.textContent.trim()) continue;
        if (n.parentElement.closest('.cm-tex-math-inline')) continue;
        const r = document.createRange();
        r.selectNodeContents(n);
        for (const b of r.getClientRects()) {
          if (b.width > 0) rects.push({ kind: 'text', x: b.x, y: b.y, w: b.width, h: b.height });
        }
      }
      let count = 0;
      for (const a of rects.filter((r) => r.kind === 'widget')) {
        for (const b of rects.filter((r) => r.kind === 'text')) {
          const sameRow = Math.abs(a.y - b.y) < a.h * 0.6;
          const xOverlap = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
          if (sameRow && xOverlap > 2) count++;
        }
      }
      return count;
    });
    ok('math revealed', (await content(page)).includes('\\mathbb{R}^{n \\times k}'));
    ok('zero widget/text overlaps', overlaps === 0, `overlaps=${overlaps}`);
  },
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'source mode: vertical snap gated off',
  'aaaa aaaa\naa $x+y$ bb\ncccc cccc\n',
  async (page, ok) => {
    await setCursor(page, 5);
    // Cmd+: cycles preview -> mixed -> source -> preview (Task 2), so it
    // takes two presses to land on source. Each press uses the same
    // platform-fallback pattern: Control+Shift+Semicolon is a no-op on
    // macOS chromium (Mod maps to Meta there), in which case the raw-math
    // check after it stays false and the Meta variant is tried too. The
    // Meta press is likewise a no-op on non-mac chromium, so exactly one of
    // the two presses per iteration actually advances the cycle.
    for (let i = 0; i < 2; i++) {
      await page.keyboard.press('Control+Shift+Semicolon'); // Mod-: (chromium linux/mac-agnostic path)
      await page.waitForTimeout(100);
      if (!(await content(page)).includes('$x+y$')) {
        // macOS chromium maps Mod to Meta.
        await page.keyboard.press('Meta+Shift+Semicolon');
        await page.waitForTimeout(100);
      }
    }
    const raw = (await content(page)).includes('$x+y$');
    ok('source mode active', raw);
    await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(70);
    const st = await page.evaluate(STATE);
    const inMath = await page.evaluate(
      (h) => { const d = window.__chalkDebugView.state.doc.toString();
        return h >= d.indexOf('$') && h <= d.lastIndexOf('$'); },
      st.head,
    );
    ok('caret may land inside raw math (no snap)', inMath, `head=${st.head}`);
  },
);

// ---------------------------------------------------------------------------
// Widget geometry on hanging-indented lines. Both defects here were invisible
// to jsdom (no layout) and to the block-level checks above; they need real
// boxes. Owner-reported 2026-08-17 as "inline previewing is broken and
// sometimes overlaps with text".
await scenario(
  browser,
  'widgets on indented lines keep their own geometry',
  '- first item with inline math $\\sum_{i=1}^n x_i \\varepsilon_i$\n' +
    '- **Households**: the budget constraint\n' +
    '  $$c_t + \\frac{M_t}{p_t} = y$$\n' +
    '- last item\n',
  async (page, ok) => {
    // 1. `text-indent` inherits into an inline-block widget and re-applies to
    //    its own first line box, painting the formula `--chalk-hang` to the
    //    LEFT of its box and over the preceding word.
    const spill = await page.evaluate(() => {
      const out = [];
      for (const span of document.querySelectorAll('.cm-math-inline')) {
        const html = span.querySelector('.katex-html');
        if (!html) continue;
        out.push(
          Math.round((span.getBoundingClientRect().left - html.getBoundingClientRect().left) * 10) / 10,
        );
      }
      return out;
    });
    ok(
      'inline math paints inside its own box',
      spill.length > 0 && spill.every((s) => s <= 0.5),
      `spill left: ${JSON.stringify(spill)}`,
    );

    // 2. A `block: true` replace must cover whole lines: an indented `$$`
    //    otherwise leaves its indent behind as a stray blank row.
    const stray = await page.evaluate(() =>
      [...document.querySelector('.cm-content').children]
        .filter(
          (e) =>
            e.classList.contains('cm-line') &&
            e.textContent.length > 0 &&
            e.textContent.trim().length === 0,
        )
        .map((e) => JSON.stringify(e.textContent)),
    );
    ok('indented display math leaves no stray row', stray.length === 0, stray.join(' '));

    // 3. Nothing paints on top of the row above it.
    const overlaps = await page.evaluate(() => {
      const kids = [...document.querySelector('.cm-content').children];
      const bad = [];
      for (let i = 1; i < kids.length; i++) {
        const a = kids[i - 1].getBoundingClientRect();
        const b = kids[i].getBoundingClientRect();
        if (b.top < a.bottom - 0.5) bad.push(`${i - 1}->${i}`);
      }
      return bad;
    });
    ok('no block overlaps its predecessor', overlaps.length === 0, overlaps.join(' '));
  },
  { width: 584, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// Paragraph-interior `$$…$$` (InlineDisplayMath): an inline replace whose
// widget makes its own row. Pins the geometry the jsdom suite cannot see —
// the equation row sits between the prose rows at full width, the row before
// it keeps start alignment under `text-align: justify` (forced <br>, not a
// wrapped break), the prose after it keeps a list item's hanging indent (no
// anonymous block boxes) — and the vertical contract: Up/Down pass over the
// rendered row at the goal column without landing on a widget edge, which
// would reveal the source.
const INLINE_DISPLAY_PARA =
  'Assuming $\\beta R =1$, this becomes $$ c_{0} = \\frac{r}{1+r}(s_{0}+h_{0}) $$ ' +
  '$\\Rightarrow$ Consumption is the annuity value of total wealth (smoothing!)';
await scenario(
  browser,
  'paragraph-interior display math makes its own row',
  'intro line\n\n' + INLINE_DISPLAY_PARA + '\n\n- first item\n- **Households**: ' +
    INLINE_DISPLAY_PARA + '\n- last item\n\nafter line\n',
  async (page, ok) => {
    const GEOM = () => {
      const content = document.querySelector('.cm-content');
      const cr = content.getBoundingClientRect();
      const rect = (needle, root) => {
        const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        while (w.nextNode()) {
          const n = w.currentNode;
          const i = n.textContent.indexOf(needle);
          if (i < 0) continue;
          const r = document.createRange();
          r.setStart(n, i);
          r.setEnd(n, i + needle.length);
          const b = r.getBoundingClientRect();
          return { x: b.x, right: b.right, top: b.top, bottom: b.bottom };
        }
        return null;
      };
      const lines = [];
      for (const line of content.querySelectorAll('.cm-line')) {
        const row = line.querySelector('.cm-math-inline-display-row');
        if (!row) continue;
        const rr = row.getBoundingClientRect();
        // The `$\Rightarrow$` widget right after the equation: first thing on
        // the row below it, so its left edge is that row's text start.
        const after = [...line.querySelectorAll('.cm-math-inline')].find(
          (e) => row.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING,
        );
        lines.push({
          before: rect('becomes', line),
          row: { left: rr.left, right: rr.right, top: rr.top, bottom: rr.bottom },
          afterLeft: after ? after.getBoundingClientRect().left : null,
          consumption: rect('Consumption', line),
          lineLeft: line.getBoundingClientRect().left,
        });
      }
      const stray = [...content.children].filter(
        (e) => e.classList.contains('cm-line') && e.textContent.length > 0 && e.textContent.trim().length === 0,
      ).length;
      return { content: { left: cr.left, right: cr.right }, lines, stray,
               overflow: content.scrollWidth - content.clientWidth };
    };
    await setCursor(page, 0);
    const g = await page.evaluate(GEOM);
    ok('both paragraphs render an equation row', g.lines.length === 2);
    ok('no stray row', g.stray === 0);
    ok('no horizontal overflow', g.overflow === 0, `${g.overflow}px`);
    for (const [i, l] of g.lines.entries()) {
      const tag = i === 0 ? 'paragraph' : 'list item';
      ok(`${tag}: the equation row sits below the prose before it`,
         l.before && l.row.top >= l.before.bottom - 1, JSON.stringify([l.before, l.row]));
      ok(`${tag}: the prose after starts below the equation row`,
         l.consumption && l.consumption.top >= l.row.bottom - 1, JSON.stringify([l.row, l.consumption]));
      ok(`${tag}: the equation row spans the measure`,
         l.row.right >= g.content.right - 4 && l.row.left <= l.lineLeft + 30,
         JSON.stringify([l.row, g.content]));
    }
    const li = g.lines[1];
    ok('list item: the prose after the equation keeps the hanging indent',
       li.afterLeft != null && li.afterLeft >= li.row.left - 1,
       `after ${li.afterLeft} vs row ${li.row.left}`);

    // Justify (a Settings toggle): the row before the equation ends in a
    // FORCED break and so keeps start alignment; a wrapped break would
    // stretch "this becomes" across the measure.
    await page.evaluate(() => document.documentElement.style.setProperty('--chalk-text-align', 'justify'));
    await page.waitForTimeout(150);
    const j = await page.evaluate(GEOM);
    ok('justify: the prose row before the equation is not stretched',
       j.lines[0].before.right < g.content.right - 60 &&
         Math.abs(j.lines[0].before.right - g.lines[0].before.right) < 2,
       `becomes right ${j.lines[0].before.right} (start: ${g.lines[0].before.right}), content right ${g.content.right}`);
    await page.evaluate(() => document.documentElement.style.removeProperty('--chalk-text-align'));
    await page.waitForTimeout(150);

    // Vertical contract on the plain paragraph.
    const para = await page.evaluate((needle) => {
      const v = window.__chalkDebugView;
      const doc = v.state.doc.toString();
      const from = doc.indexOf('$$');
      return { lineFrom: v.state.doc.lineAt(from).from, from, to: doc.indexOf('$$', from + 2) + 2 };
    }, '$$');
    await setCursor(page, para.lineFrom + 3);
    await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(120);
    const down = await page.evaluate(STATE);
    const rendered = async () => !(await content(page)).includes('$$');
    ok('Down passes over the equation to the row below',
       down.head > para.to && down.head < para.lineFrom + INLINE_DISPLAY_PARA.length,
       JSON.stringify(down));
    ok('Down keeps the equation rendered', await rendered());
    ok('Down keeps the goal column', down.x != null && Math.abs(down.x - 57) < 12, `x ${down.x}`);
    await page.keyboard.press('ArrowUp');
    await page.waitForTimeout(120);
    const up = await page.evaluate(STATE);
    ok('Up passes back over the equation to the row above',
       up.head >= para.lineFrom && up.head < para.from, JSON.stringify(up));
    ok('Up keeps the equation rendered', await rendered());
    ok('Up keeps the goal column', up.head === para.lineFrom + 3, `head ${up.head}`);

    // A click on the formula reveals it, with the preview under the paragraph.
    await setCursor(page, 0);
    await page.waitForTimeout(100);
    const r = await page.evaluate(() => {
      const b = document.querySelector('.cm-math-inline-display-row .katex').getBoundingClientRect();
      return { x: b.x + b.width / 2, y: b.y + b.height / 2 };
    });
    await page.mouse.click(r.x, r.y);
    await page.waitForTimeout(150);
    const clicked = await page.evaluate(STATE);
    ok('click reveals the source', (await content(page)).includes('$$ c_{0}'));
    ok('click parks the caret inside the equation', clicked.head >= para.from && clicked.head < para.to, JSON.stringify(clicked));
    ok('a preview renders under the paragraph', await page.evaluate(() => !!document.querySelector('.cm-math-preview .katex')));
  },
  { width: 584, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// Trailing punctuation stays glued to the construct it follows. A rendered
// formula is `display: inline-block` and CM6's own `.cm-widgetBuffer` cursor
// anchors are `<img>` elements: both are atomic inline boxes, and the browser
// grants a soft wrap opportunity on BOTH sides of one even with no adjacent
// whitespace. At the wrong measure that strands the `!` or the `,` alone at
// the start of the next row. The `cm-math-glue` / `cm-live-glue` nowrap marks
// suppress it. Swept across widths because a single width proves nothing:
// only some measures put the construct at the wrap edge.
//
// This scenario is also the guard against measuring a CRASHED plugin. A
// throw from a decoration builder makes CM6 drop the whole plugin, the
// construct falls back to raw source, and an orphan count then reads 0 for
// the wrong reason — which is exactly how a broken version of this fix once
// passed. So the shape assertions below run first.
await scenario(
  browser,
  'trailing punctuation never wraps alone',
  "We have obtained a sequence of policy functions $c_t^*(a_{t-1})$ and $V_t(a_{t-1})$!\n\n" +
    "To obtain $V'_{t+1}(a_{t})$, take the derivative with respect to the *state*, $a_{t-1}$:\n\n" +
    'Consider *a fairly long emphasized clause that runs on for a while*, and then some more prose.\n',
  async (page, ok) => {
    const shape = await page.evaluate(() => {
      const lines = [...document.querySelectorAll('.cm-line')];
      return {
        raw: lines.map((l) => l.textContent).join('').includes('$'),
        math: lines[0].querySelectorAll('.cm-math-inline').length,
        mathGlued: lines[0].querySelectorAll('.cm-math-glue > .cm-math-inline').length,
        italic: lines[2].querySelectorAll('.cm-live-italic').length,
        italicGlued: lines[2].querySelectorAll('.cm-live-glue .cm-live-italic').length,
      };
    });
    ok('the formulas rendered (no crashed plugin behind a 0 count)',
       shape.math === 2 && !shape.raw, JSON.stringify(shape));
    ok('the formula before `!` carries the nowrap glue', shape.mathGlued === 1, JSON.stringify(shape));
    ok('the emphasis rendered', shape.italic === 1, JSON.stringify(shape));
    ok('the emphasis before `,` carries the nowrap glue', shape.italicGlued === 1, JSON.stringify(shape));

    // For each width, the punctuation's own client rect must not jump back to
    // the left of where its anchor ends — that leftward jump IS the new row.
    const sweep = async (lineIndex, selector) => {
      let measured = 0;
      const orphans = [];
      for (let width = 200; width <= 560; width += 4) {
        await page.setViewportSize({ width, height: 900 });
        await page.waitForTimeout(15);
        const r = await page.evaluate(
          ([i, sel]) => {
            const line = document.querySelectorAll('.cm-line')[i];
            const el = [...line.querySelectorAll(sel)].pop();
            if (!el) return null;
            const anchor = el.getBoundingClientRect();
            let node = el.nextSibling;
            while (node && node.nodeType !== Node.TEXT_NODE) node = node.nextSibling;
            if (!node) return null;
            const range = document.createRange();
            range.selectNodeContents(node);
            const first = range.getClientRects()[0];
            if (!first) return null;
            return { right: Math.round(anchor.right), left: Math.round(first.left) };
          },
          [lineIndex, selector],
        );
        if (!r) continue;
        measured++;
        if (r.left < r.right - 20) orphans.push(width);
      }
      return { measured, orphans };
    };

    const m = await sweep(0, '.cm-math-inline');
    ok('`$V_t(a_{t-1})$!` — the `!` keeps the formula\'s row at every width',
       m.measured > 50 && m.orphans.length === 0, JSON.stringify(m));
    const i = await sweep(2, '.cm-live-italic');
    ok('`*state*,` — the `,` keeps the emphasis\'s row at every width',
       i.measured > 50 && i.orphans.length === 0, JSON.stringify(i));

    // The glue must not make a long emphasised run unbreakable: it reaches
    // back only to the last word, and CM6 splits the styling mark around it.
    await page.setViewportSize({ width: 300, height: 900 });
    await page.waitForTimeout(60);
    const long = await page.evaluate(() => {
      const line = document.querySelectorAll('.cm-line')[4];
      const c = document.querySelector('.cm-content');
      const glue = line.querySelector('.cm-live-glue');
      return { overflow: c.scrollWidth - c.clientWidth,
               glueText: glue ? glue.textContent : null,
               rows: line.querySelector('.cm-live-italic').getClientRects().length };
    });
    ok('a long emphasised run still wraps inside the measure',
       long.overflow === 0 && long.rows > 1, JSON.stringify(long));
    ok('the glue reaches back only to the last word',
       long.glueText === 'while,', JSON.stringify(long));
    await page.setViewportSize({ width: 584, height: 900 });
  },
  { width: 584, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// A wrapped row never opens with a space. Every rendered construct ends in an
// atomic inline box: the KaTeX widget is `inline-block`, and CM6 puts an
// `<img class="cm-widgetBuffer">` after every replaced range. CSS grants a
// soft wrap opportunity right after an atomic box, which is BEFORE the space
// that follows it, and under CM6's own `white-space: break-spaces` a space
// never hangs past the edge. So whenever the construct fitted and the space
// did not, the engine broke before the space and the next row opened with it
// (`because $\varepsilon$ is finite` put ` is finite` on the next row).
// vsCodeTheme switches wrapped lines to `pre-wrap`, where that space hangs.
// Swept across widths for the same reason as the punctuation scenario: only a
// construct ending within one space of the edge shows it.
const sweepLeadingSpaces = async (page) => {
  let measured = 0;
  const offenders = [];
  for (let width = 200; width <= 700; width += 3) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(15);
    const hits = await page.evaluate(() => {
      const out = [];
      for (const line of document.querySelectorAll('.cm-line')) {
        const box = line.getBoundingClientRect();
        const left = box.left + parseFloat(getComputedStyle(line).paddingLeft);
        const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          for (let i = 0; i < node.length; i++) {
            if (node.textContent[i] !== ' ') continue;
            const range = document.createRange();
            range.setStart(node, i);
            range.setEnd(node, i + 1);
            const r = range.getClientRects()[0];
            // A visible space flush with the text column's left edge, below
            // the line's first row, is a row that opens with a space.
            if (r && r.width > 1 && Math.abs(r.left - left) < 1.5 && r.top > box.top + 5) {
              out.push(node.textContent.slice(i, i + 12));
            }
          }
        }
      }
      return out;
    });
    measured++;
    if (hits.length) offenders.push({ width, rows: hits });
  }
  await page.setViewportSize({ width: 584, height: 900 });
  return { measured, offenders: offenders.length, first: offenders.slice(0, 4) };
};

await scenario(
  browser,
  'tex: a wrapped row never opens with a space',
  'The marginal product $F_q$ goes to infinity as $q_t \\to 0$, because $\\varepsilon$ is finite. ' +
    'See \\ref{eq:one} and \\cite{smith2020} for \\textit{details}, then \\textbf{bold} again and \\emph{e} f.\n\n' +
    'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon\n\n' +
    'park\n',
  async (page, ok) => {
    const shape = await page.evaluate(() => ({
      math: document.querySelectorAll('.cm-line')[0].querySelectorAll('.cm-tex-math-inline').length,
      raw: document.querySelectorAll('.cm-line')[0].textContent.includes('$'),
    }));
    ok('the formulas rendered (no crashed plugin behind a 0 count)',
       shape.math === 3 && !shape.raw, JSON.stringify(shape));
    const s = await sweepLeadingSpaces(page);
    ok('no row opens with the space after a construct, at any width',
       s.measured > 150 && s.offenders === 0, JSON.stringify(s));

    // The price of a hanging space: spaces typed at a row end run past the
    // text column instead of wrapping. They must not give the scroller
    // horizontal overflow, or CM6 scrolls the whole page sideways to follow
    // the caret.
    await page.setViewportSize({ width: 420, height: 900 });
    await page.waitForTimeout(60);
    const rowEnd = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const line = v.state.doc.line(3);
      const top = v.coordsAtPos(line.from).top;
      let end = line.from;
      for (let p = line.from + 1; p <= line.to; p++) {
        if (v.coordsAtPos(p, -1).top > top + 5) break;
        if (v.state.sliceDoc(p, p + 1) === ' ') end = p;
      }
      v.dispatch({ selection: { anchor: end } });
      v.focus();
      return end;
    });
    for (let k = 0; k < 8; k++) await page.keyboard.press('Space');
    await page.waitForTimeout(150);
    const scroll = await page.evaluate((end) => {
      const d = window.__chalkDebugView.scrollDOM;
      return { rowEnd: end, scrollLeft: d.scrollLeft, overflow: d.scrollWidth - d.clientWidth };
    }, rowEnd);
    ok('spaces typed at a row end never scroll the editor sideways',
       scroll.scrollLeft === 0 && scroll.overflow <= 0, JSON.stringify(scroll));
  },
  { width: 584, height: 900 },
);

await scenario(
  browser,
  'md: a wrapped row never opens with a space',
  'The marginal product $F_q$ goes to infinity as $q_t \\to 0$, because $\\varepsilon$ is finite. ' +
    'See **bold words** and *state*, $a_{t-1}$ and `code span` then [a link](http://x.y) and ==marked== again.\n\n' +
    'park\n',
  async (page, ok) => {
    const shape = await page.evaluate(() => ({
      math: document.querySelectorAll('.cm-line')[0].querySelectorAll('.cm-math-inline').length,
      raw: document.querySelectorAll('.cm-line')[0].textContent.includes('$'),
    }));
    ok('the formulas rendered (no crashed plugin behind a 0 count)',
       shape.math === 4 && !shape.raw, JSON.stringify(shape));
    const s = await sweepLeadingSpaces(page);
    ok('no row opens with the space after a construct, at any width',
       s.measured > 150 && s.offenders === 0, JSON.stringify(s));
  },
  { width: 584, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// Completion popup: the whole path — real typing opens it, real Enter applies
// it, and the caret lands in the first tab stop. jsdom can assert the text but
// not where the caret ends up relative to a widget-rendered block, and the
// auto-closed `}` from closeBrackets only appears when the keys are real.
await scenario(
  browser,
  'completion popup inserts a figure and lands in its first tab stop',
  'intro line\n\n',
  async (page, ok) => {
    await setCursor(page, 11);
    await page.keyboard.type('\\begin{fig');
    await page.waitForTimeout(300);
    ok('popup is open', (await page.locator('.cm-tooltip-autocomplete').count()) > 0);

    await page.keyboard.press('Enter');
    await page.waitForTimeout(300);
    const text = await page.evaluate(() => window.__chalkDebugView.state.doc.toString());
    ok('figure block inserted', text.includes('\\includegraphics[width=0.8\\textwidth]{}'));
    ok('no literal tab-stop markers', !text.includes('$1') && !text.includes('$0'));
    ok('brace not duplicated', !text.includes('\\begin{figure}}'));

    const st = await page.evaluate(STATE);
    const atStop = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const h = v.state.selection.main.head;
      return v.state.sliceDoc(h - 1, h + 1);
    });
    ok('caret sits between the includegraphics braces', atStop === '{}', atStop);
    ok('caret is on the includegraphics line', st.line === 4, `line ${st.line}`);

    await page.keyboard.press('Tab');
    await page.waitForTimeout(200);
    const afterTab = await page.evaluate(STATE);
    ok('Tab steps to the caption stop', afterTab.line === 5, `line ${afterTab.line}`);
  },
);

// ---------------------------------------------------------------------------
// MARKDOWN vertical motion. Everything above pins the tex branch; markdown ran
// on CM6's defaults until md-vertical-motion.ts, and both defects need real
// layout to show:
//   - a landing inside `$…$` reveals the raw source, which is wider than the
//     widget, so the line reflows mid-motion and the caret ends up somewhere
//     the user never aimed at ("it jumped into the math");
//   - `mdMathArrowKeymap` fires on DOCUMENT-line adjacency, so a soft-wrapped
//     paragraph directly above a `$$` block used to teleport into the math on
//     the first Down instead of walking its own visual rows.
await scenario(
  browser,
  'md: Up/Down keeps the goal column across a display-math stop',
  'aaaa aaaa aaaa aaaa aaaa\n$$\n\\alpha = \\beta\n$$\nbbbb bbbb bbbb bbbb bbbb\ncccc cccc cccc cccc cccc\n',
  async (page, ok) => {
    // mdMathArrowKeymap dispatches its own landing at column 2 (the `$$`
    // line's length). CM6's per-range goalColumn does not survive that
    // dispatch, so before md-vertical-motion.ts the caret stayed at column 2
    // for the rest of the document (measured: x 210 -> 46, never recovering).
    await setCursor(page, 18);
    const before = await page.evaluate(STATE);
    for (let i = 0; i < 5; i++) {
      await page.keyboard.press('ArrowDown');
      await page.waitForTimeout(50);
    }
    await page.waitForTimeout(80);
    const st = await page.evaluate(STATE);
    ok('walked past the math block', st.line >= 5, `line ${st.line}`);
    ok('goal column survived the stop', Math.abs(st.x - before.x) <= 6,
       `x ${before.x} -> ${st.x} (col ${st.col}, was ${before.col})`);
  },
  { width: 584, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
await scenario(
  browser,
  'md: wrapped paragraph above $$ walks its rows first',
  'a soft wrapped paragraph long enough to occupy several visual rows in this '
    + 'narrow viewport so the first Down press has somewhere to go\n'
    + '$$\n\\alpha = \\beta\n$$\n'
    + 'trailing prose that is also long enough to wrap across more than one '
    + 'visual row in this narrow viewport\n',
  async (page, ok) => {
    await setCursor(page, 0);
    await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(80);
    const down = await page.evaluate(STATE);
    ok('Down stays on the wrapped paragraph', down.line === 1, `line ${down.line}`);
    ok('Down actually moved', down.head > 0, `head ${down.head}`);

    // From the LAST wrapped row the stop must still fire.
    for (let i = 0; i < 8; i++) await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(120);
    const entered = await page.evaluate(STATE);
    ok('Down eventually enters the math block', entered.line >= 2,
       `line ${entered.line}`);

    // Same contract upward from the trailing wrapped paragraph. The doc ends
    // with a newline, so the prose is the SECOND-to-last document line.
    const target = await page.evaluate(() => {
      const d = window.__chalkDebugView.state.doc;
      const line = d.line(d.lines - 1);
      return { number: line.number, pos: Math.min(line.from + 60, line.to) };
    });
    await setCursor(page, target.pos);
    await page.keyboard.press('ArrowUp');
    await page.waitForTimeout(80);
    const up = await page.evaluate(STATE);
    ok('Up stays on the trailing wrapped paragraph', up.line === target.number,
       `line ${up.line}, expected ${target.number}`);
  },
  { width: 420, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// The popup is part of the editing surface, not chrome: an option must be set
// in the same face and size as the text it will insert, so the row reads as a
// preview of the edit. Computed styles need a real browser — jsdom resolves
// neither the CM6-injected stylesheet nor the `var()` chain behind it.
await scenario(
  browser,
  'completion popup is typeset like the editor',
  'intro line\n\n',
  async (page, ok) => {
    await setCursor(page, 11);
    await page.keyboard.type('\\sec');
    await page.waitForTimeout(300);
    ok('popup is open', (await page.locator('.cm-tooltip-autocomplete').count()) > 0);

    const type = await page.evaluate(() => {
      const style = (sel, prop) => {
        const el = document.querySelector(sel);
        return el ? getComputedStyle(el).getPropertyValue(prop) : null;
      };
      return {
        labelSize: style('.cm-completionLabel', 'font-size'),
        contentSize: style('.cm-content', 'font-size'),
        labelFamily: style('.cm-completionLabel', 'font-family'),
        contentFamily: style('.cm-content', 'font-family'),
        detailSize: style('.cm-completionDetail', 'font-size'),
        radius: style('.cm-tooltip-autocomplete', 'border-radius'),
      };
    });
    ok('label matches the editor font size', type.labelSize === type.contentSize,
       `${type.labelSize} vs ${type.contentSize}`);
    ok('label matches the editor font family', type.labelFamily === type.contentFamily,
       `${type.labelFamily}`);
    ok('detail is set smaller than the label',
       parseFloat(type.detailSize) < parseFloat(type.labelSize),
       `${type.detailSize} vs ${type.labelSize}`);
    ok('surface is rounded like the find panel', parseFloat(type.radius) >= 10, type.radius);
  },
);

// ---------------------------------------------------------------------------
// Path completion over the REAL native transport. native-host.ts posts
// `list-files` to `webkit.messageHandlers.chalkHost` and settles the promise
// when Swift calls `__chalkHost.listFilesReply(id, paths)`; nothing else
// exercises that request/reply plumbing, and jsdom cannot (the bundle binds
// the bridge at boot). A stub bridge here plays Swift's part.
//
// Also pins the fix for the silent `![]()` slot: landing on a snippet tab
// stop is a selection-only transaction, which does not carry the `input.type`
// user event CM6's activateOnTyping watches, so the popup has to be started
// explicitly (hsnips-plugin's offerCompletionsAtStop).
await scenario(
  browser,
  'md: image path completion over the host bridge',
  '# Notes\n\n',
  async (page, ok) => {
    await page.evaluate(() => {
      const v = window.__chalkDebugView;
      v.dispatch({ selection: { anchor: v.state.doc.length } });
      v.focus();
    });

    // 1. Typing into the parens asks the host and renders what it answers.
    await page.keyboard.type('![](');
    await page.waitForTimeout(500);
    const sent = await page.evaluate(() => window.__stubSent.filter((m) => m.type === 'list-files'));
    ok('asked the host for images', sent.length === 1 && sent[0].kinds.join() === 'image',
       JSON.stringify(sent));
    ok('popup lists the host answer',
       (await page.locator('.cm-tooltip-autocomplete li').count()) === 3);

    // 2. Accepting inserts the path.
    await page.keyboard.press('Escape');
    await page.evaluate(() => {
      const v = window.__chalkDebugView;
      v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: '# Notes\n\n' },
                   selection: { anchor: 9 } });
    });

    // 3. The figure snippet: Tab into the image slot must offer files with no
    //    keystroke of its own.
    await page.keyboard.type('::: ');
    await page.waitForTimeout(300);
    await page.keyboard.press('Enter'); // accept `figure`
    await page.waitForTimeout(300);
    ok('figure snippet inserted',
       (await page.evaluate(() => window.__chalkDebugView.state.doc.toString())).includes('![]('));
    await page.keyboard.press('Tab'); // label slug → image path
    await page.waitForTimeout(500);
    const atSlot = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const h = v.state.selection.main.head;
      return v.state.doc.lineAt(h).text;
    });
    ok('caret sits in the image path line', atSlot.includes('![]('), atSlot);
    ok('file list opened without typing',
       (await page.locator('.cm-tooltip-autocomplete li').count()) === 3);

    // 4. And on a plain caret move back into the empty slot — real arrow
    //    keys, through preview reveal and the pointer/selection machinery
    //    that jsdom cannot express.
    await page.keyboard.press('Escape');
    await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const line = v.state.doc.line(v.state.doc.lineAt(v.state.selection.main.head).number);
      v.dispatch({ selection: { anchor: line.to } });
      v.focus();
    });
    await page.waitForTimeout(200);
    ok('popup closed after Escape',
       (await page.locator('.cm-tooltip-autocomplete').count()) === 0);
    await page.keyboard.press('ArrowLeft'); // end of `![]()` → between the parens
    await page.waitForTimeout(500);
    const where = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const h = v.state.selection.main.head;
      return v.state.sliceDoc(h - 1, h + 1);
    });
    ok('caret is between the parens', where === '()', where);
    ok('file list reopened on the caret move',
       (await page.locator('.cm-tooltip-autocomplete li').count()) === 3);
  },
  { width: 760, height: 900 },
  'md',
  () => {
    window.__stubSent = [];
    window.webkit = {
      messageHandlers: {
        chalkHost: {
          postMessage(m) {
            window.__stubSent.push(m);
            if (m.type === 'list-files') {
              setTimeout(() => window.__chalkHost.listFilesReply(m.id,
                ['figures/growth.png', 'figures/scan.jpg', 'diagram.pdf']), 5);
            }
            if (m.type === 'read-text') {
              setTimeout(() => window.__chalkHost.readTextReply(m.id, null), 5);
            }
          },
        },
      },
    };
  },
);

// ---------------------------------------------------------------------------
// The find panel is an overlay pinned to the editor's top edge, and BOTH native
// shells run the webview full-bleed under their chrome band — only `.cm-content`
// is padded down by `--chalk-chrome-top`. The panel inherited the webview's
// origin instead, so from the day overlay chrome landed (2026-08-03) Cmd+F
// opened a panel that the opaque tab strip painted straight over: pressing it
// looked like a dead shortcut. Pin the panel BELOW the band the shell declares.
await scenario(
  browser,
  'find panel clears the shell chrome band',
  'hello world\nsecond line hello\nthird line\n',
  async (page, ok) => {
    const BAND = 52; // a Mac titlebar + resting pad, as the shell publishes it
    await page.evaluate((px) => {
      document.documentElement.style.setProperty('--chalk-chrome-top', `${px}px`);
    }, BAND);
    await page.click('.cm-content');
    await page.keyboard.press('Meta+f');
    await page.waitForTimeout(250);

    const geom = await page.evaluate(() => {
      const panel = document.querySelector('.chalk-find');
      const line = document.querySelector('.cm-line');
      return {
        panelTop: panel ? panel.getBoundingClientRect().top : null,
        lineTop: line ? line.getBoundingClientRect().top : null,
        focused: document.activeElement?.className ?? '',
      };
    });
    ok('panel opened on Cmd+F', geom.panelTop !== null);
    ok('the query input took focus', geom.focused === 'chalk-find__input', geom.focused);
    ok('text rests below the band', geom.lineTop >= BAND, `lineTop=${geom.lineTop}`);
    ok('panel rests below the band too', geom.panelTop >= BAND, `panelTop=${geom.panelTop}`);

    // With no shell (VS Code, plain browser) the variable is absent and the
    // panel must stay where it always sat, at the editor's own top edge.
    await page.keyboard.press('Escape');
    await page.evaluate(() =>
      document.documentElement.style.removeProperty('--chalk-chrome-top'));
    await page.click('.cm-content');
    await page.keyboard.press('Meta+f');
    await page.waitForTimeout(250);
    const bare = await page.evaluate(() =>
      document.querySelector('.chalk-find').getBoundingClientRect().top);
    ok('no chrome variable → panel back at the top edge', bare < 20, `top=${bare}`);
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// The find panel is typeset FROM the editor's font size, not from a fixed pixel
// scale: the query is text you match against the document, so it is set like the
// document (the contract the completion popup already keeps). Every dimension
// inside is `em`, so the count and the toggles stay subordinate to the query at
// every zoom step instead of converging on it. Owner report 2026-08-18: at the
// 17px default the 13px input already read as too small.
await scenario(
  browser,
  'find panel is typeset from the editor font',
  'hello world\nsecond line hello\nthird line hello\n',
  async (page, ok) => {
    const openAt = async (fontPx, bandPx) => {
      await page.evaluate(([f, b]) => {
        const root = document.documentElement;
        root.style.setProperty('--vscode-editor-font-size', `${f}px`);
        root.style.setProperty('--chalk-chrome-top', `${b}px`);
      }, [fontPx, bandPx]);
      await page.click('.cm-content');
      await page.keyboard.press('Meta+f');
      await page.waitForTimeout(220);
      return page.evaluate(() => {
        const px = (el, prop = 'fontSize') => parseFloat(getComputedStyle(el)[prop]);
        const panel = document.querySelector('.chalk-find');
        return {
          content: px(document.querySelector('.cm-content')),
          input: px(document.querySelector('.chalk-find__input')),
          count: px(document.querySelector('.chalk-find__count')),
          toggle: px(document.querySelector('.chalk-find__toggle')),
          btnH: document.querySelector('.chalk-find__icon-btn').getBoundingClientRect().height,
          glyphW: document.querySelector('.chalk-find__icon-btn svg').getBoundingClientRect().width,
          panelTop: panel.getBoundingClientRect().top,
          panelW: panel.getBoundingClientRect().width,
        };
      });
    };
    const close = async () => {
      await page.keyboard.press('Escape');
      await page.waitForTimeout(120);
    };

    const small = await openAt(17, 52);
    ok('query is set at the editor size', small.input === small.content,
       `input=${small.input} content=${small.content}`);
    ok('count stays subordinate to the query', small.count < small.input,
       `count=${small.count} input=${small.input}`);
    ok('toggles stay subordinate too', small.toggle < small.input);
    ok('panel clears the band at 17px', small.panelTop >= 52, `top=${small.panelTop}`);
    await close();

    // Zoom the editor: the whole panel must travel with it, chrome included.
    const large = await openAt(24, 52);
    ok('query follows the editor to 24px', large.input === large.content,
       `input=${large.input} content=${large.content}`);
    ok('count scales with the panel', large.count > small.count,
       `${small.count} -> ${large.count}`);
    ok('icon buttons scale with the panel', large.btnH > small.btnH,
       `${small.btnH} -> ${large.btnH}`);
    ok('icon glyphs scale with their button', large.glyphW > small.glyphW,
       `${small.glyphW} -> ${large.glyphW}`);
    ok('panel widens with its type', large.panelW > small.panelW,
       `${small.panelW} -> ${large.panelW}`);
    ok('taller panel still clears the band', large.panelTop >= 52, `top=${large.panelTop}`);
    // The overlay must not eat the column it floats over.
    const vw = await page.evaluate(() => window.innerWidth);
    ok('panel stays within the viewport', large.panelW <= vw * 0.92,
       `panel=${large.panelW} vw=${vw}`);

    // The replace row is folded away on open, so its own scale is easy to miss.
    await page.click('.chalk-find__expand');
    await page.waitForTimeout(200);
    const rep = await page.evaluate(() => {
      const btn = document.querySelector('.chalk-find__text-btn');
      const input = document.querySelector('.chalk-find__replace .chalk-find__input');
      return {
        visible: getComputedStyle(document.querySelector('.chalk-find__replace')).display,
        btnFont: parseFloat(getComputedStyle(btn).fontSize),
        replaceFont: parseFloat(getComputedStyle(input).fontSize),
      };
    });
    ok('replace row opened', rep.visible === 'flex', rep.visible);
    ok('replace field matches the query field', rep.replaceFont === large.input,
       `${rep.replaceFont} vs ${large.input}`);
    ok('Replace/All buttons scale with the panel', rep.btnFont > 11,
       `btnFont=${rep.btnFont}`);
  },
  { width: 760, height: 900 },
  'md',
);

// ---------------------------------------------------------------------------
// Typewriter centering must not turn a click into a drag-select.
//
// The centering rAF scrolls the document out from under a still-pressed
// button; CM6's MouseSelection then re-reads posAtCoords on the next pointer
// move and extends the selection over everything the scroll travelled
// (owner report 2026-08-18, "clicking selects the whole paragraph"). A real
// hand always moves a pixel or two between press and release, so the plain
// click below carries a 2px jitter — without it the bug is invisible.
for (const language of ['tex', 'md']) {
  await scenario(
    browser,
    `typewriter click stays a caret (${language})`,
    'aaaa filler one\naaaa filler two\naaaa filler three\n' +
      'This paragraph is long enough to wrap over several visual rows in the ' +
      'probe viewport, so a click that lands in the middle of it is a ' +
      'realistic gesture for the centering scroll to disturb.\n' +
      'park line\nAnother paragraph follows so a runaway selection has ' +
      'somewhere to run to before the document ends.\ntail line\n',
    async (page, ok) => {
      await page.evaluate(() =>
        window.__chalkHost.receive({ type: 'editor-config', config: { editingMode: 'typewriter' } }),
      );
      await page.waitForTimeout(300);
      const r = await page.evaluate(FIND_TEXT, 'realistic');
      ok('found the click target', r !== null);
      if (!r) return;
      const x = r.x + r.w / 2;
      const y = r.y + r.h / 2;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await page.waitForTimeout(60); // let the centering rAF land mid-gesture
      await page.mouse.move(x + 2, y + 1); // hand jitter
      await page.mouse.up();
      await page.waitForTimeout(300);
      const text = await page.evaluate(SEL_TEXT);
      // Not `empty`: CM6 has no drag threshold, so a 2px jitter grabs the one
      // character the pointer crossed in EVERY mode. The regression is
      // paragraph-scale, so the bar is parity with a normal-mode click.
      ok('click selects no more than the pointer crossed', text.length <= 2,
         `selected ${text.length} chars ${JSON.stringify(text.slice(0, 60))}`);

      // Centering must still happen, just deferred to the release. Compare
      // against the keyboard path (the untouched centering route) rather than
      // a magic pixel: scrollMargins from comfortable-scroll deliberately pull
      // the centered line above the true viewport middle.
      const CARET_OFFSET = () => {
        const v = window.__chalkDebugView;
        const c = v.coordsAtPos(v.state.selection.main.head);
        const box = v.scrollDOM.getBoundingClientRect();
        return (c.top + c.bottom) / 2 - (box.top + box.bottom) / 2;
      };
      const afterRelease = await page.evaluate(CARET_OFFSET);
      await page.keyboard.press('ArrowRight');
      await page.waitForTimeout(300);
      const afterKey = await page.evaluate(CARET_OFFSET);
      ok('release centering matches the keyboard centering',
         Math.abs(afterRelease - afterKey) < 8,
         `release=${Math.round(afterRelease)} key=${Math.round(afterKey)}`);
    },
    { width: 760, height: 700 },
    language,
    null,
  );
}

// ---------------------------------------------------------------------------
// A press on a rendered formula must place a caret, never select the widget.
//
// A replaced widget exposes only two coordinate-addressable positions (its
// start and its end), so CM6's posAtCoords flips between them on the first
// pixel of hand tremor and drag-selects the WHOLE source range — a display
// block looked like "clicking selected the entire paragraph" (owner report
// 2026-08-18). Inline tex math was already immune via its dead-zone handler;
// display tex and both markdown shapes were not. The 3px jitter is the point
// of the test: without it the bug is invisible.
for (const [language, doc, widgets] of [
  [
    'tex',
    'filler alpha line\n' +
      'Prose with inline math $a^2+b^2=c^2$ embedded in it.\n' +
      '\\begin{equation}\\label{eq:main}\nE = mc^2\n\\end{equation}\n' +
      'tail alpha line\n',
    [['display', '.cm-tex-math-display', 'E = mc^2'], ['inline', '.cm-tex-math-inline', 'a^2+b^2']],
  ],
  [
    'md',
    'filler alpha line\n' +
      'Prose with inline math $a^2+b^2=c^2$ embedded in it.\n' +
      '$$\nE = mc^2\n$$\n' +
      'tail alpha line\n',
    [['display', '.cm-math-display', 'E = mc^2'], ['inline', '.cm-math-inline', 'a^2+b^2']],
  ],
]) {
  await scenario(
    browser,
    `formula press places a caret (${language})`,
    doc,
    async (page, ok) => {
      for (const [kind, css, source] of widgets) {
        const r = await page.evaluate((c) => {
          const e = document.querySelector(c);
          if (!e) return null;
          const b = e.getBoundingClientRect();
          return { x: b.x, y: b.y, w: b.width, h: b.height };
        }, css);
        ok(`${kind}: widget rendered`, r !== null, css);
        if (!r) continue;
        const x = r.x + r.w / 2;
        const y = r.y + r.h / 2;
        await page.mouse.move(x, y);
        await page.mouse.down();
        await page.waitForTimeout(60);
        await page.mouse.move(x + 3, y + 2); // hand jitter
        await page.mouse.up();
        await page.waitForTimeout(300);

        const text = await page.evaluate(SEL_TEXT);
        ok(`${kind}: press left a caret, not a whole-widget selection`, text.length === 0,
           `selected ${text.length} chars ${JSON.stringify(text.slice(0, 50))}`);

        // The press must still do its job: the caret lands inside the region,
        // so the raw source replaces the rendered widget.
        const revealed = await page.evaluate((src) =>
          document.querySelector('.cm-content').innerText.includes(src), source);
        ok(`${kind}: source revealed under the caret`, revealed, source);

        // Park the caret away so the next widget is rendered again.
        await setCursor(page, 0);
        await page.waitForTimeout(300);
      }
    },
    { width: 760, height: 700 },
    language,
    null,
  );
}

// ---------------------------------------------------------------------------
// The selected band must stop where the text stops.
//
// CM6's drawSelection derives the full-width part of a multi-line selection
// from `contentDOM.getBoundingClientRect()` corrected only by `.cm-line`'s
// padding (rectanglesForRange). A bounding rect is a BORDER box, so any
// horizontal padding on `.cm-content` is invisible to that math and the band
// paints that much too wide on both sides — reported 2026-08-18 as the
// highlight overflowing the text column. The shell's side buffers therefore
// must not live on `.cm-content`; this pins that they don't.
for (const sidePad of [20, 40]) {
  await scenario(
    browser,
    `selection band stays inside the text column (side pad ${sidePad}px)`,
    'alpha line one that is long enough to reach the right edge of the measure\n' +
      'beta line two also long enough to wrap or at least fill the row nicely\n' +
      'gamma tail line\n',
    async (page, ok) => {
      await page.evaluate((p) => {
        document.documentElement.style.setProperty('--chalk-side-pad', `${p}px`);
      }, sidePad);
      await page.evaluate(() => {
        const v = window.__chalkDebugView;
        v.dispatch({ selection: { anchor: 0, head: v.state.doc.length } });
        v.focus();
      });
      await page.waitForTimeout(300);

      const m = await page.evaluate(() => {
        const c = document.querySelector('.cm-content');
        const cs = getComputedStyle(c);
        const r = c.getBoundingClientRect();
        return {
          // The text column: `.cm-content`'s CONTENT box.
          left: r.left + parseFloat(cs.paddingLeft),
          right: r.right - parseFloat(cs.paddingRight),
          bands: [...document.querySelectorAll('.cm-selectionBackground')].map((d) => {
            const b = d.getBoundingClientRect();
            return { left: b.left, right: b.right };
          }),
        };
      });

      ok('selection drew bands', m.bands.length > 0, `${m.bands.length} bands`);
      const overflow = m.bands.filter((b) => b.left < m.left - 1 || b.right > m.right + 1);
      ok(
        'no band bleeds into the side buffers',
        overflow.length === 0,
        `column [${m.left.toFixed(1)}, ${m.right.toFixed(1)}] vs ` +
          overflow.map((b) => `[${b.left.toFixed(1)}, ${b.right.toFixed(1)}]`).join(' '),
      );
    },
    { width: 900, height: 700 },
    'md',
    null,
  );
}

// ---------------------------------------------------------------------------
// The selection paints ONE colour.
//
// CM6 draws a selection as several rectangles, and it overlaps two of them on
// a line where a rendered construct of 20+ source characters splits its visible
// ranges (rectanglesForRange marks both halves "open" to the left edge; still
// true in @codemirror/view 6.43.12). With the translucency on each rectangle,
// the overlap painted darker: half a line in one shade, half in another. Its
// focused colour also lost to CM6's base theme, whose `.cm-focused > .cm-scroller
// > .cm-selectionLayer` selector outranked ours, so the theme colour only ever
// showed while the editor was blurred (owner report 2026-09-16).
//
// Pixels are read from real screenshots: the claim is about what is painted.

/** RGB of the viewport pixel at (x, y). A 1x1 clip's first pixel is also its
 *  scanline's first byte group, which every PNG row filter leaves raw (no left
 *  neighbour, no prior row), so no full decoder is needed. */
async function pixelAt(page, x, y) {
  const png = await page.screenshot({ clip: { x: Math.floor(x), y: Math.floor(y), width: 1, height: 1 } });
  const idat = [];
  for (let off = 8; off < png.length; ) {
    const len = png.readUInt32BE(off);
    const type = png.toString('ascii', off + 4, off + 8);
    if (type === 'IDAT') idat.push(png.subarray(off + 8, off + 8 + len));
    off += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  return [raw[1], raw[2], raw[3]];
}

const sameColour = (a, b) => a.every((c, i) => Math.abs(c - b[i]) <= 2);

await scenario(
  browser,
  'a selection paints one colour across a line with a rendered formula',
  'A first line of prose that sits above the formula line here.\n' +
    'Inline maths, \\( \\alpha \\to \\beta + \\gamma \\), renders in the line.\n' +
    'park\n',
  async (page, ok) => {
    const doc = await page.evaluate(() => window.__chalkDebugView.state.doc.toString());
    await page.evaluate(
      ([a, h]) => {
        const v = window.__chalkDebugView;
        v.focus();
        v.dispatch({ selection: { anchor: a, head: h } });
      },
      [doc.indexOf('prose'), doc.indexOf(' in the line')],
    );
    await page.waitForTimeout(300);
    // Centres of word gaps (no glyph ink): one inside the overlapped left part
    // of the row, one past the formula, one on the row above.
    const gap = (needle) =>
      page.evaluate((n) => {
        const v = window.__chalkDebugView;
        const p = v.state.doc.toString().indexOf(n);
        const a = v.coordsAtPos(p);
        const b = v.coordsAtPos(p + 1);
        return [(a.left + b.left) / 2, (a.top + a.bottom) / 2];
      }, needle);
    const left = await pixelAt(page, ...(await gap(' maths,')));
    const right = await pixelAt(page, ...(await gap(' renders')));
    const above = await pixelAt(page, ...(await gap(' that sits')));
    ok('left of the formula matches right of it', sameColour(left, right), `${left} vs ${right}`);
    ok('the row above matches too', sameColour(above, right), `${above} vs ${right}`);
  },
  { width: 760, height: 300 },
  'tex',
);

await scenario(
  browser,
  'the selection uses the theme colours, focused and blurred',
  'alpha beta gamma\ndelta\n',
  async (page, ok) => {
    const read = () =>
      page.evaluate(() => {
        const probe = document.createElement('div');
        document.body.appendChild(probe);
        const resolve = (v) => {
          probe.style.backgroundColor = `var(${v})`;
          return getComputedStyle(probe).backgroundColor;
        };
        const rect = document.querySelector('.cm-selectionBackground');
        const out = {
          painted: rect && getComputedStyle(rect).backgroundColor,
          active: resolve('--vscode-editor-selectionBackground'),
          inactive: resolve('--vscode-editor-inactiveSelectionBackground'),
        };
        probe.remove();
        return out;
      });
    await page.evaluate(() => {
      const v = window.__chalkDebugView;
      v.focus();
      v.dispatch({ selection: { anchor: 0, head: 11 } });
    });
    await page.waitForTimeout(200);
    const focused = await read();
    ok('focused paints the active colour', focused.painted === focused.active, JSON.stringify(focused));
    await page.evaluate(() => window.__chalkDebugView.contentDOM.blur());
    await page.waitForTimeout(200);
    const blurred = await read();
    ok('blurred paints the inactive colour', blurred.painted === blurred.inactive, JSON.stringify(blurred));
  },
  { width: 600, height: 200 },
  'md',
);

// ---------------------------------------------------------------------------
// Releasing a drag never reflows the document.
//
// A selection passing over a theorem or a display equation used to reveal its
// source (fences for any overlap, display math whenever the head was on its
// row). The pointer gesture defers reveals to the release, so the release is
// where rows appeared, everything below shifted, and CM6 re-resolved the
// selection end against the moved text. Now only a selection anchored on the
// construct, or one with an end stranded in its hidden text, reveals it.
for (const [label, target] of [
  ['onto a rendered equation', 'EQUATION'],
  ['into a theorem body', 'Body sentence'],
  ['past a theorem to the next paragraph', 'Closing'],
]) {
  await scenario(
    browser,
    `releasing a drag ${label} does not reflow`,
    'Opening paragraph with enough words to click into comfortably.\n\n' +
      '\\[ \\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6} \\]\n\n' +
      '\\begin{theorem}[Pythagoras]\nBody sentence of the theorem.\n\\end{theorem}\n\n' +
      'Closing paragraph.\n',
    async (page, ok) => {
      const from = await page.evaluate(FIND_TEXT, 'enough');
      const to =
        target === 'EQUATION'
          ? await page.evaluate(FIND_CSS, '.cm-tex-math-display')
          : await page.evaluate(FIND_TEXT, target);
      const snap = () =>
        page.evaluate(() => {
          const v = window.__chalkDebugView;
          const m = v.state.selection.main;
          return {
            h: Math.round(document.querySelector('.cm-content').getBoundingClientRect().height),
            text: document.querySelector('.cm-content').textContent,
            sel: [m.anchor, m.head],
          };
        });
      await page.mouse.move(from.x + 4, from.y + from.h / 2);
      await page.mouse.down();
      const tx = to.x + Math.min(to.w / 2, 60);
      const ty = to.y + to.h / 2;
      for (let i = 1; i <= 8; i++) {
        await page.mouse.move(from.x + 4 + ((tx - from.x - 4) * i) / 8, from.y + from.h / 2 + ((ty - from.y - from.h / 2) * i) / 8);
      }
      await page.waitForTimeout(150);
      const held = await snap();
      await page.mouse.up();
      await page.waitForTimeout(300);
      const released = await snap();
      ok('selection is non-empty', held.sel[0] !== held.sel[1], JSON.stringify(held.sel));
      ok('no source revealed on release', released.text === held.text,
        released.text.replace(held.text, '…').slice(0, 120));
      ok('document height unchanged on release', released.h === held.h, `${held.h} -> ${released.h}`);
      ok('selection unchanged on release', released.sel.join() === held.sel.join(),
        `${held.sel} -> ${released.sel}`);
    },
    { width: 760, height: 700 },
    'tex',
  );
}

// ---------------------------------------------------------------------------
// Beamer slide cards. The card is N stacked line boxes faking one box, drawn
// with inset shadows, negative horizontal margins and two collapsed fences —
// every one of which is a geometry claim jsdom cannot check. What matters is
// that the rows form a CONTIGUOUS column and that clicks still land on the
// line the user aimed at, which is exactly what a margined block breaks.
await scenario(
  browser,
  'beamer slide card geometry',
  '\\documentclass{beamer}\n' +
    '\\begin{frame}{Bayesian updating}{a worked example}\n' +
    'first body line\n' +
    'second body line\n' +
    'third body line\n' +
    '\\end{frame}\n' +
    '\n' +
    'park line for the caret\n',
  async (page, ok) => {
    await setCursor(page, 0);
    await page.waitForTimeout(150);

    const geom = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.cm-line')].map((el) => {
        const b = el.getBoundingClientRect();
        return {
          text: el.textContent,
          slide: el.classList.contains('cm-slide'),
          top: b.top,
          bottom: b.bottom,
          left: b.left,
          right: b.right,
        };
      });
      return { rows };
    });

    const card = geom.rows.filter((r) => r.slide);
    ok(
      'card spans header, three body rows and the foot',
      card.length === 5,
      `${card.length} rows`,
    );

    // Contiguity: a vertical margin (or a stray collapsed-fence row) would show
    // up here as a gap or an overlap between consecutive rows of the card.
    const gaps = [];
    for (let i = 1; i < card.length; i++) {
      const gap = card[i].top - card[i - 1].bottom;
      if (Math.abs(gap) > 1) gaps.push(gap.toFixed(2));
    }
    ok('card rows are contiguous, no margin gaps', gaps.length === 0, `gaps: ${gaps.join(', ')}`);

    // All rows share one left and one right edge, so the box reads as a box.
    const lefts = new Set(card.map((r) => Math.round(r.left)));
    const rights = new Set(card.map((r) => Math.round(r.right)));
    ok('card rows share a left edge', lefts.size === 1, [...lefts].join(' '));
    ok('card rows share a right edge', rights.size === 1, [...rights].join(' '));

    // The collapsed \end{frame} occupies no visual row.
    const text = await content(page);
    ok('closing fence is collapsed', !text.includes('\\end{frame}'));
    ok('header renders the title', text.includes('Bayesian updating'));
    ok('header renders the subtitle', text.includes('a worked example'));

    // A click inside a card body row must land on THAT row. This is the check
    // that a margined block breaks: posAtCoords drifts and the caret arrives
    // several lines away.
    const target = await page.evaluate(FIND_TEXT, 'second body line');
    await page.mouse.click(target.x + target.w / 2, target.y + target.h / 2);
    await page.waitForTimeout(150);
    const landed = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      return v.state.doc.lineAt(v.state.selection.main.head).text;
    });
    ok('click inside the card lands on the clicked row', landed.includes('second body line'), landed);

    // Down from the last body row must reach the collapsed fence (revealing
    // it) rather than skipping the card's end entirely.
    await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(120);
    await page.keyboard.press('ArrowDown');
    await page.waitForTimeout(150);
    const afterDown = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      return v.state.doc.lineAt(v.state.selection.main.head).text;
    });
    ok('vertical motion reaches the collapsed fence', afterDown.includes('\\end{frame}'), afterDown);
  },
);

// ---------------------------------------------------------------------------
// A beamer block inside a frame is the NORMAL case for a deck. The card's edges
// are inset shadows drawn on EACH row, so they only stay put if every row of
// the card shares the same box. Insetting the nested block by shifting its
// margins moved the card's own edge inward on those rows and broke the outline
// open beside every block — which an "is the block inset?" check happily
// passes. Assert the edges instead.
await scenario(
  browser,
  'the card outline survives a nested block',
  '\\documentclass{beamer}\n' +
    '\\begin{frame}{A result}\n' +
    'lead in\n' +
    '\\begin{block}{Takeaway}\n' +
    'the posterior is conjugate\n' +
    '\\end{block}\n' +
    'trailing\n' +
    '\\end{frame}\n' +
    '\n' +
    'park line for the caret\n',
  async (page, ok) => {
    await setCursor(page, 0);
    await page.waitForTimeout(150);

    const m = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.cm-line.cm-slide')].map((el) => {
        const b = el.getBoundingClientRect();
        return {
          nested: el.classList.contains('cm-callout'),
          left: Math.round(b.left),
          right: Math.round(b.right),
        };
      });
      return { rows, nested: rows.filter((r) => r.nested).length };
    });

    ok('the block rows are inside the card', m.nested === 2, `${m.nested} nested rows`);
    const lefts = new Set(m.rows.map((r) => r.left));
    const rights = new Set(m.rows.map((r) => r.right));
    ok(
      'every card row shares a left edge, nested ones included',
      lefts.size === 1,
      [...lefts].join(' '),
    );
    ok(
      'every card row shares a right edge, nested ones included',
      rights.size === 1,
      [...rights].join(' '),
    );

    // …and the box is genuinely inset. The row keeps the card's geometry, so
    // the nesting lives entirely in the ::before that paints the tint and bar;
    // measuring the row alone would report the card's own edges and pass while
    // the block sat flush against them.
    const inset = await page.evaluate(() => {
      const row = document.querySelector('.cm-line.cm-slide.cm-callout');
      const cs = getComputedStyle(row, '::before');
      return { left: parseFloat(cs.left), right: parseFloat(cs.right), radius: cs.borderTopLeftRadius };
    });
    ok(
      'the nested box is painted inset from the card edges',
      inset.left > 4 && inset.right > 4,
      `left ${inset.left} right ${inset.right}`,
    );
    ok('the nested box keeps its rounded top', parseFloat(inset.radius) > 0, inset.radius);
  },
);

// ---------------------------------------------------------------------------
// The two title syntaxes must produce the SAME card. The brace form's header is
// a widget; the \frametitle form is real source across two rows. Only a real
// browser can tell you the two bands are the same height — an early cut put a
// `display: block` subtitle inside the inline widget, which split the line's
// inline flow into anonymous blocks and left an empty one trailing, making the
// brace form's band a full line taller for identical content.
await scenario(
  browser,
  'both frame title syntaxes render the same band',
  '\\documentclass{beamer}\n' +
    '\\begin{frame}{Bayesian updating}{a worked example}\n' +
    'body\n' +
    '\\end{frame}\n' +
    '\n' +
    '\\begin{frame}[t]\n' +
    '    \\frametitle{Bayesian updating}\n' +
    '    \\framesubtitle{a worked example}\n' +
    'body\n' +
    '\\end{frame}\n' +
    '\n' +
    'park line for the caret\n',
  async (page, ok) => {
    await setCursor(page, 0);
    await page.waitForTimeout(150);

    const m = await page.evaluate(() => {
      const rows = [...document.querySelectorAll('.cm-line.cm-slide-band')];
      const heights = rows.map((r) => r.getBoundingClientRect().height);
      const lefts = rows.map((r) => {
        // x of the first rendered glyph on the row, so the source indent of the
        // \frametitle form shows up if it is not being hidden.
        const walker = document.createTreeWalker(r, NodeFilter.SHOW_TEXT);
        if (!walker.nextNode()) return null;
        const range = document.createRange();
        range.selectNodeContents(walker.currentNode);
        return range.getBoundingClientRect().left;
      });
      return { braceBand: heights[0], commandBand: heights[1] + heights[2], lefts };
    });

    ok(
      'both bands are the same height',
      Math.abs(m.braceBand - m.commandBand) < 1,
      `brace ${m.braceBand.toFixed(1)} vs command ${m.commandBand.toFixed(1)}`,
    );

    const titleLefts = [m.lefts[0], m.lefts[1]].filter((v) => v != null);
    ok(
      'both titles start at the same x (source indent is hidden)',
      titleLefts.length === 2 && Math.abs(titleLefts[0] - titleLefts[1]) < 1,
      titleLefts.map((v) => v.toFixed(1)).join(' vs '),
    );
  },
);


// ---------------------------------------------------------------------------
// Breathing room under the title band's closing rule. The space has to come
// from the first body row's padding-top (the rule sits at the band row's bottom
// edge, and a margin is forbidden), and it is applied with an adjacent-sibling
// selector so it survives a collapsed fence sitting between the two in the
// SOURCE — `\begin{itemize}` renders no element, so the DOM sibling after the
// band is the first visible content row either way.
await scenario(
  browser,
  'the title band is spaced off the frame body',
  '\\documentclass{beamer}\n' +
    '\\begin{frame}{With a list}{a subtitle}\n' +
    '\\begin{itemize}\n' +
    '\\item first content line\n' +
    '\\end{itemize}\n' +
    '\\end{frame}\n' +
    '\n' +
    '\\begin{frame}{Without one}{a subtitle}\n' +
    'plain first line\n' +
    '\\end{frame}\n' +
    '\n' +
    'park line for the caret\n',
  async (page, ok) => {
    await setCursor(page, 0);
    await page.waitForTimeout(150);

    const bands = await page.evaluate(() =>
      [...document.querySelectorAll('.cm-slide-band-end')].map((b) => {
        const next = b.nextElementSibling;
        return {
          next: (next.textContent || '').trim(),
          above: parseFloat(getComputedStyle(b).paddingBottom),
          below: parseFloat(getComputedStyle(next).paddingTop),
        };
      }),
    );

    ok('both frames render a band', bands.length === 2, `${bands.length}`);
    for (const b of bands) {
      ok(
        `content is spaced below the rule (${b.next.slice(0, 18)})`,
        b.below > 4,
        `above ${b.above} below ${b.below}`,
      );
    }
    // The list frame is the one whose \begin{itemize} collapses between the
    // band and the first \item; both must land on real content, not a fence.
    ok(
      'the spaced row is real content, not a collapsed fence',
      bands.every((b) => b.next.length > 0),
      bands.map((b) => JSON.stringify(b.next)).join(' '),
    );
  },
);


// ---------------------------------------------------------------------------
// Reveal oracle smoke. The jsdom twin (test/debug-probe.test.ts) pins each
// construct's hidden set at chosen caret positions; this walks a real caret
// through a whole document with REAL Right presses and asserts the oracle at
// every step, against real geometry and the real (WebKit-shippable) engine:
//   O-1  every hidden range lies inside a construct extent hardcoded for
//        this doc — nothing else in the document is ever concealed;
//   O-3  domVisibleLines == expectedVisibleLines — the DOM shows exactly the
//        text the hidden set implies, no stale widget or half-revealed row;
//   no stale reveal — each construct is hidden exactly when the caret is
//        outside its reveal window (inline char-window [from,to); display
//        line-window; command window [cmdFrom, to+1); fence line).
{
  const DOC =
    'Given $a+b$ and \\textbf{bold} see \\ref{fig:one}\n' +
    '\\[\n' +
    'E = mc^2\n' +
    '\\]\n' +
    'plain prose here\n' +
    '\\begin{theorem}\n' +
    'inner lead\n' +
    '\\[\n' +
    'x^2\n' +
    '\\]\n' +
    '\\end{theorem}\n' +
    'tail line\n';

  const idx = (s, from = 0) => DOC.indexOf(s, from);
  // Hardcoded construct extents for THIS doc (O-1's whitelist).
  const inline = { from: idx('$'), to: idx('$', idx('$') + 1) + 1 };
  const bf = { cmdFrom: idx('\\textbf'), end: idx('}', idx('\\textbf')) + 1 };
  const ref = { cmdFrom: idx('\\ref'), end: idx('}', idx('\\ref')) + 1 };
  const d1 = { from: idx('\\['), to: idx('\\]') + 2 };
  const d2 = { from: idx('\\[', d1.to), to: idx('\\]', idx('\\[', d1.to) + 2) + 2 };
  const thmOpen = { from: idx('\\begin{theorem}'), to: idx('\\begin{theorem}') + 15 };
  const thmClose = { from: idx('\\end{theorem}'), to: idx('\\end{theorem}') + 13 };

  const lineStarts = [0];
  for (let i = 0; i < DOC.length; i++) if (DOC[i] === '\n') lineStarts.push(i + 1);
  const lineOf = (pos) => {
    let n = 0;
    while (n + 1 < lineStarts.length && lineStarts[n + 1] <= pos) n++;
    return n + 1;
  };

  // O-1 whitelist. The theorem's trailing display math may absorb the
  // collapsed \end{theorem} fence into its block replace (calloutBlockAt's
  // hideTo), and the fence's own hide starts at the previous line's end —
  // both live inside [d2.from, thmClose.to].
  const extents = [
    [inline.from, inline.to],
    [bf.cmdFrom, bf.end],
    [ref.cmdFrom, ref.end],
    [d1.from, d1.to],
    [d2.from, thmClose.to],
    [thmOpen.from, thmOpen.to],
  ];

  // Per-construct reveal rules, replicated from the plugins' contracts.
  // `span` is the source range whose hides count as this construct's;
  // `sig` are positions that MUST be inside some hidden range whenever the
  // construct is concealed (a split hide like `\textbf{` + `}` covers the
  // command's two ends but not the argument between them).
  const constructs = [
    { name: 'inline $a+b$', span: [inline.from, inline.to], sig: [inline.from, inline.to - 1],
      revealed: (h) => h >= inline.from && h < inline.to },
    { name: '\\textbf', span: [bf.cmdFrom, bf.end], sig: [bf.cmdFrom, bf.end - 1],
      revealed: (h) => h >= bf.cmdFrom && h < bf.end },
    { name: '\\ref pill', span: [ref.cmdFrom, ref.end], sig: [ref.cmdFrom, ref.end - 1],
      revealed: (h) => h >= ref.cmdFrom && h < ref.end },
    { name: 'display 1', span: [d1.from, d1.to], sig: [d1.from, d1.to - 1],
      revealed: (h) => lineOf(h) >= lineOf(d1.from) && lineOf(h) <= lineOf(d1.to - 1) },
    { name: 'display 2', span: [d2.from, d2.to], sig: [d2.from, d2.to - 1],
      revealed: (h) => lineOf(h) >= lineOf(d2.from) && lineOf(h) <= lineOf(d2.to - 1) },
    { name: 'theorem open fence', span: [thmOpen.from, thmOpen.to], sig: [thmOpen.from, thmOpen.to - 1],
      revealed: (h) => lineOf(h) === lineOf(thmOpen.from) },
    { name: 'theorem close fence', span: [thmClose.from, thmClose.to], sig: [thmClose.from, thmClose.to - 1],
      revealed: (h) => lineOf(h) === lineOf(thmClose.from) },
  ];

  await scenario(
    browser,
    'reveal oracle smoke',
    DOC,
    async (page, ok) => {
      await setCursor(page, 0);
      await page.waitForTimeout(100);

      const violations = { extent: [], oracle: [], reveal: [] };
      let head = 0;
      let steps = 0;
      const maxSteps = DOC.length + 20;

      while (head < DOC.length && steps < maxSteps) {
        await page.keyboard.press('ArrowRight');
        await page.waitForTimeout(15);
        steps++;
        const probe = await page.evaluate(() => ({
          snap: window.__chalkDebugProbe.snapshot(),
          expected: window.__chalkDebugProbe.expectedLines(),
        }));
        const { snap, expected } = probe;
        if (snap.head === head) break; // end of document (or a stuck caret)
        head = snap.head;

        // O-1: nothing outside the construct extents is ever hidden.
        for (const h of snap.hidden) {
          if (!extents.some(([f, t]) => h.from >= f && h.to <= t)) {
            violations.extent.push(`head=${head}: hidden [${h.from},${h.to}) outside every extent`);
          }
        }

        // O-3: the DOM shows exactly what the hidden set implies.
        if (JSON.stringify(snap.domLines) !== JSON.stringify(expected)) {
          violations.oracle.push(
            `head=${head}: dom ${JSON.stringify(snap.domLines)} != expected ${JSON.stringify(expected)}`,
          );
        }

        // No stale reveal / no missing conceal, per construct.
        for (const c of constructs) {
          const overlaps = snap.hidden.filter((h) => h.from < c.span[1] && h.to > c.span[0]);
          if (c.revealed(head) && overlaps.length) {
            violations.reveal.push(`head=${head}: ${c.name} should be revealed but has hides`);
          }
          const covered = (p) => snap.hidden.some((h) => h.from <= p && p < h.to);
          if (!c.revealed(head) && !c.sig.every(covered)) {
            violations.reveal.push(`head=${head}: ${c.name} should be concealed but is not covered`);
          }
        }
      }

      ok('walk reached the end of the document', head >= DOC.length - 1, `head=${head} after ${steps} steps`);
      ok('O-1: hidden ranges stay inside the construct extents', violations.extent.length === 0,
         `${violations.extent.length} violations; first: ${violations.extent[0]}`);
      ok('O-3: DOM lines equal the expected visible lines at every step', violations.oracle.length === 0,
         `${violations.oracle.length} violations; first: ${violations.oracle[0]}`);
      ok('no stale reveal: constructs hide exactly per their windows', violations.reveal.length === 0,
         `${violations.reveal.length} violations; first: ${violations.reveal[0]}`);
    },
    { width: 760, height: 900 },
    'tex',
  );
}

// ---------------------------------------------------------------------------
//  Shift+Arrow inside a concealed construct keeps it editable.
//
//  A concealed construct REPLACES part of its source, and a replace decoration
//  holds no DOM position: when a selection end lands in a replaced range, CM6
//  resolves it to the range's outer edge. The caret visibly jumped out of the
//  construct and the next keystroke was inserted there instead of replacing the
//  selection (reported for `$E_{z_{t+1}}$`, then found across the family).
//
//  Only a real browser shows it — the STATE selection stayed right the whole
//  time, so jsdom sees nothing. Its twin, asserting the cause rather than the
//  symptom, is test/reveal-under-selection.test.ts.
// ---------------------------------------------------------------------------
{
  const PARK = '\npark line\n';
  const CASES = [
    { lang: 'tex', what: 'inline math', doc: 'Consider $E_{z_{t+1}}$ here.' + PARK,
      caret: 21, presses: 2, raw: '$E_{z_{t+1}}$', sel: '}}',
      typed: 'Consider $E_{z_{t+1X$ here.' },
    { lang: 'md', what: 'inline math', doc: 'Consider $E_{z_{t+1}}$ here.' + PARK,
      caret: 21, presses: 2, raw: '$E_{z_{t+1}}$', sel: '}}',
      typed: 'Consider $E_{z_{t+1X$ here.' },
    { lang: 'tex', what: 'a \\ref pill', doc: 'See \\ref{eq:main} now.' + PARK,
      caret: 12, presses: 2, raw: '\\ref{eq:main}', sel: 'q:',
      typed: 'See \\ref{eXmain} now.' },
    { lang: 'tex', what: 'the \\textbf command name', doc: 'A \\textbf{word} here.' + PARK,
      caret: 6, presses: 2, raw: '\\textbf{', sel: 'ex',
      typed: 'A \\tXtbf{word} here.' },
    { lang: 'tex', what: 'an \\includegraphics path', doc: 'Fig: \\includegraphics{a.png} end.' + PARK,
      caret: 25, presses: 2, raw: '\\includegraphics{', sel: '.p',
      typed: 'Fig: \\includegraphics{aXng} end.' },
    { lang: 'tex', what: 'an \\item token', doc: '\\begin{itemize}\n\\item one\n\\end{itemize}\n',
      caret: 20, presses: 2, raw: '\\item', sel: 'te',
      typed: '\\begin{itemize}' , docHas: '\\iXm one' },
    { lang: 'md', what: 'a bold marker', doc: 'A **bold** word.' + PARK,
      caret: 3, presses: 1, raw: '**', sel: '*', typed: 'A X*bold** word.' },
    { lang: 'md', what: 'an image path', doc: 'Fig ![alt](a.png) end.' + PARK,
      caret: 14, presses: 2, raw: '![alt](a.png)', sel: '.p',
      typed: 'Fig ![alt](aXng) end.' },
    { lang: 'md', what: 'a heading id', doc: '# Title {#sec-one}\n\nbody\n',
      caret: 16, presses: 2, raw: '{#sec-one}', sel: 'on',
      typed: '# Title {#sec-Xe}' },
  ];

  /** Whether the browser caret sits on real text rather than a widget edge. */
  const ON_TEXT = () => {
    const n = document.getSelection().focusNode;
    return n ? n.nodeType === 3 : false;
  };

  for (const c of CASES) {
    await scenario(
      browser,
      `selecting inside ${c.what} keeps it editable (${c.lang})`,
      c.doc,
      async (page, ok) => {
        await setCursor(page, c.caret);
        await page.waitForTimeout(120);
        ok('source is revealed for the caret', (await content(page)).includes(c.raw));

        for (let i = 0; i < c.presses; i++) await page.keyboard.press('Shift+ArrowLeft');
        await page.waitForTimeout(120);

        ok('it stays revealed under the selection', (await content(page)).includes(c.raw));
        ok('the selected text is what was selected',
           (await page.evaluate(SEL_TEXT)) === c.sel, JSON.stringify(await page.evaluate(SEL_TEXT)));
        ok('the browser caret is on real text, not a widget edge', await page.evaluate(ON_TEXT));

        // The payload: the keystroke must replace the selection IN PLACE.
        await page.keyboard.type('X');
        await page.waitForTimeout(120);
        const doc = await page.evaluate(() => window.__chalkDebugView.state.doc.toString());
        ok('typing replaced the selection inside the construct',
           doc.includes(c.docHas ?? c.typed), JSON.stringify(doc.split('\n')[0]));
      },
      { width: 760, height: 900 },
      c.lang,
    );
  }
}

// ---------------------------------------------------------------------------
// Mixed view mode (R-X2): fences are ordinary rows, math still reveals.
await scenario(
  browser,
  'mixed: md fences are default motion, math still reveals',
  'top line\n::: {#thm-a}\nbody $x^2$ here\n:::\nafter line\n',
  async (page, ok) => {
    ok('fence is raw', (await content(page)).includes('::: {#thm-a}'));
    await setCursor(page, 0);
    await page.keyboard.press('ArrowDown');
    let st = await page.evaluate(STATE);
    ok('Down lands on the open fence row', st.line === 2, `line ${st.line}`);
    await page.keyboard.press('ArrowDown');
    await page.keyboard.press('ArrowDown');
    st = await page.evaluate(STATE);
    ok('two more Downs land on the close fence row', st.line === 4, `line ${st.line}`);
    const hidden = await page.evaluate(() => window.__chalkDebugProbe.hidden());
    const mathFrom = 'top line\n::: {#thm-a}\nbody '.length;
    const mathTo = mathFrom + '$x^2$'.length;
    ok(
      'the only hidden range is the math',
      hidden.length >= 1 && hidden.every((h) => h.from >= mathFrom && h.to <= mathTo),
      JSON.stringify(hidden),
    );
    const r = await page.evaluate(FIND_TEXT, 'body ');
    await page.mouse.click(r.x + r.w + 8, r.y + r.h / 2);
    await page.waitForTimeout(120);
    ok('clicking the formula reveals its source', (await content(page)).includes('$x^2$'));
  },
  { width: 760, height: 900 },
  'md',
  null,
  { viewMode: 'mixed' },
);

await scenario(
  browser,
  'mixed: tex theorem and \\emph stay as source, inline math reveals',
  'top line\n\\begin{theorem}[Pythagoras]\nA \\emph{right} triangle has $a^2+b^2=c^2$.\n\\end{theorem}\nafter line\n',
  async (page, ok) => {
    const c = await content(page);
    ok('open fence is raw', c.includes('\\begin{theorem}[Pythagoras]'));
    ok('close fence is raw', c.includes('\\end{theorem}'));
    ok('\\emph shows its command', c.includes('\\emph{right}'));
    ok('inline math is rendered', !c.includes('$a^2'));
    await setCursor(page, 0);
    await page.keyboard.press('ArrowDown');
    const st = await page.evaluate(STATE);
    ok('Down lands on the fence row', st.line === 2, `line ${st.line}`);
  },
  { width: 760, height: 900 },
  'tex',
  null,
  { viewMode: 'mixed' },
);

// ---------------------------------------------------------------------------
//  French (AZERTY) dead key: `a`, `^`, `2` must leave `a^2`, never `a^^2`.
//
//  On a French Mac keyboard `^` is a dead key, so it reaches the page as an
//  IME composition rather than a keystroke: `compositionstart`, the browser
//  writes `^` into the caret's text node as marked text, `compositionupdate`;
//  the next non-composable key (`2`) commits it with `compositionend` and
//  then inserts itself. CodeMirror reads that DOM mutation while
//  `view.composing` is true, so an engine transaction that rewrites the
//  composed line — or a decoration rebuild that drops the node holding the
//  marked text — makes the `^` land twice (owner report 2026-09-11: `a^^2`).
//
//  Playwright cannot drive the macOS input method, so the lane synthesises
//  the browser-level sequence: a real `Text.insertData` under an open
//  composition, in both commit orders (`compositionend` before the `2`, and
//  the `2` arriving while the composition is still open), after a dwell
//  longer than display-math's 150 ms preview debounce so a debounced
//  effects-only transaction lands mid-composition. The real snippet file is
//  loaded, so hsnips auto-expansion is live on the composed keystroke too.
//
//  What it can see: the ENGINE inserting `^` twice, which is what a plugin
//  dispatching into an open composition would produce. What it cannot see:
//  WebKit re-inserting its own marked text, which needs a real input method.
//  Nothing under packages/editor-core/src mentions `composing` today, so this
//  is the fence that keeps a future plugin out of the composition window.
// ---------------------------------------------------------------------------

const HSNIPS = readFileSync(
  resolve(repoRoot, 'packages/editor-core/assets/latex.hsnips'),
  'utf8',
);

/** Open a composition and write `ch` at the caret the way an IME does. */
const COMPOSE_START = (ch) => {
  const target = document.querySelector('.cm-content');
  target.focus();
  target.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }));
  const sel = window.getSelection();
  const range = sel.getRangeAt(0);
  let node = range.startContainer;
  let offset = range.startOffset;
  if (node.nodeType !== Node.TEXT_NODE) {
    const child = node.childNodes[offset - 1] || node.childNodes[offset];
    if (!child || child.nodeType !== Node.TEXT_NODE) return 'no text node at the caret';
    node = child;
    offset = child.length;
  }
  // A real mutation, not a dispatched event: this is the marked text, and
  // it is what CM6's DOMObserver reads while the composition is open.
  node.insertData(offset, ch);
  const after = document.createRange();
  after.setStart(node, offset + ch.length);
  after.collapse(true);
  sel.removeAllRanges();
  sel.addRange(after);
  target.dispatchEvent(new CompositionEvent('compositionupdate', { data: ch, bubbles: true }));
  return 'ok';
};

const COMPOSE_END = (ch) =>
  document
    .querySelector('.cm-content')
    .dispatchEvent(new CompositionEvent('compositionend', { data: ch, bubbles: true }));

/** Caret right after the first occurrence of `letter`. */
const CARET_AFTER = (letter) => {
  const v = window.__chalkDebugView;
  const i = v.state.doc.toString().indexOf(letter);
  if (i < 0) return -1;
  v.focus();
  v.dispatch({ selection: { anchor: i + 1 } });
  return i;
};

const DEAD_KEY_CELLS = [
  ['plain text', 'a'],
  ['inline math', 'b'],
  ['display math', 'c'],
];

const DEAD_KEY_DOCS = {
  md: 'a\n\n$b$\n\n$$\nc\n$$\n\npark line\n',
  tex: 'a\n\n$b$\n\n\\[ c \\]\n\npark line\n',
};

for (const [lang, doc] of Object.entries(DEAD_KEY_DOCS)) {
  await scenario(
    browser,
    `${lang}: french dead key ^ then 2 stays ^2`,
    doc,
    async (page, ok) => {
      for (const [where, letter] of DEAD_KEY_CELLS) {
        for (const order of ['commit-then-key', 'key-then-commit']) {
          // Fresh document per cell (init reapplies the snippets), so one
          // cell's `^2` never shifts the next cell's caret arithmetic.
          await page.evaluate(
            (m) => window.__chalkHost.receive(m),
            { type: 'init', text: doc, language: lang },
          );
          await page.evaluate(
            (s) => window.__chalkHost.receive({ type: 'hsnips', content: s }),
            HSNIPS,
          );
          await page.waitForTimeout(300);
          const placed = await page.evaluate(CARET_AFTER, letter);
          await page.waitForTimeout(250);
          const started = await page.evaluate(COMPOSE_START, '^');
          await page.waitForTimeout(220);
          if (order === 'commit-then-key') {
            await page.evaluate(COMPOSE_END, '^');
            await page.waitForTimeout(60);
            await page.keyboard.type('2');
          } else {
            await page.keyboard.type('2');
            await page.waitForTimeout(30);
            await page.evaluate(COMPOSE_END, '^');
          }
          await page.waitForTimeout(250);
          const text = await page.evaluate(
            () => window.__chalkDebugView.state.doc.toString(),
          );
          const line = text.split('\n').find((l) => l.includes('^')) ?? '';
          ok(`${where} (${order}): the composition reached a text node`,
             placed >= 0 && started === 'ok', `${placed} ${started}`);
          ok(`${where} (${order}): the dead key lands once`,
             text.includes(`${letter}^2`) && !text.includes('^^'),
             JSON.stringify(line));
        }
      }
    },
    { width: 760, height: 900 },
    lang,
  );
}


// ---------------------------------------------------------------------------
//  The SHAPE the real Catalyst WKWebView produces, replayed with real inserts.
//
//  The lane above synthesises an IME composition and proves the engine does
//  not double-insert on its own. This one replays what the owner's trace
//  actually captured inside the app: WebKit performs TWO inserts for the one
//  `2` press that commits the dead key — the committed `^`, then the key's own
//  characters `^2`, which repeat it.
//
//    keydown key=^2 code=Digit2
//    beforeinput/input inputType=deleteCompositionText   (marked ^ removed)
//    compositionend data=""
//    beforeinput/input insertText data=^    → doc a^
//    beforeinput/input insertText data=^2   → doc a^^2
//
//  `page.keyboard.insertText` is the one driver that produces a real,
//  CANCELLABLE `beforeinput insertText` in both engines (`execCommand`
//  emits no beforeinput at all in headless Chromium), so the guard in
//  editor-core/src/editor/dead-key-commit.ts is exercised for real here.
//  The bundle under test is native-host.ts, the host that turns the guard on.
// ---------------------------------------------------------------------------

/** Commit a dead-key composition of `ch` without inserting anything: the
 *  inserts arrive afterwards as WebKit's two `insertText`s. */
const COMMIT_DEAD_KEY = (ch) => {
  const target = document.querySelector('.cm-content');
  target.focus();
  target.dispatchEvent(new CompositionEvent('compositionstart', { data: '', bubbles: true }));
  target.dispatchEvent(new CompositionEvent('compositionupdate', { data: ch, bubbles: true }));
  // WebKit's compositionend for a dead key carries no data of its own.
  target.dispatchEvent(new CompositionEvent('compositionend', { data: '', bubbles: true }));
  return 'ok';
};

for (const [lang, doc] of Object.entries(DEAD_KEY_DOCS)) {
  await scenario(
    browser,
    `${lang}: the Catalyst double insert of a committed dead key`,
    doc,
    async (page, ok) => {
      for (const [where, letter] of DEAD_KEY_CELLS) {
        await page.evaluate(
          (m) => window.__chalkHost.receive(m),
          { type: 'init', text: doc, language: lang },
        );
        await page.waitForTimeout(250);
        const placed = await page.evaluate(CARET_AFTER, letter);
        await page.waitForTimeout(150);
        await page.evaluate(COMMIT_DEAD_KEY, '^');
        await page.waitForTimeout(60);
        // The two real inserts WebKit makes for the single `2` press.
        await page.keyboard.insertText('^');
        await page.keyboard.insertText('^2');
        await page.waitForTimeout(200);
        const text = await page.evaluate(
          () => window.__chalkDebugView.state.doc.toString(),
        );
        const line = text.split('\n').find((l) => l.includes('^')) ?? '';
        ok(`${where}: the caret was parked`, placed >= 0, String(placed));
        ok(`${where}: the repeated commit is dropped`,
           text.includes(`${letter}^2`) && !text.includes('^^'),
           JSON.stringify(line));
      }

      // A composable second key commits once and inserts once; nothing to drop.
      await page.evaluate(
        (m) => window.__chalkHost.receive(m),
        { type: 'init', text: doc, language: lang },
      );
      await page.waitForTimeout(250);
      await page.evaluate(CARET_AFTER, 'a');
      await page.waitForTimeout(150);
      await page.evaluate(COMMIT_DEAD_KEY, '^');
      await page.waitForTimeout(60);
      await page.keyboard.insertText('\u00ea');
      await page.waitForTimeout(200);
      const composable = await page.evaluate(
        () => window.__chalkDebugView.state.doc.toString(),
      );
      ok('a composable commit is untouched',
         composable.startsWith('a\u00ea'), JSON.stringify(composable.slice(0, 6)));
    },
    { width: 760, height: 900 },
    lang,
  );
}

// ---------------------------------------------------------------------------
// LaTeX lists are laid out from structure in Preview (tex-list-plugin.ts):
// an item's text, its wrapped rows and its continuation lines share one left
// edge, whatever the source indentation, in a proportional font too (the old
// `ch` hang only lined up in monospace). A nested item starts further right.
await scenario(
  browser,
  'tex list: item text, wrapped rows and continuation lines share an edge',
  [
    'Intro.',
    '\\begin{enumerate}',
    '    \\item Alpha first item, long enough that it wraps onto a second row in this narrow column for sure.',
    'Continuation written flush left in the source.',
    '  \\begin{itemize}',
    '  \\item Nested bullet text.',
    '  \\end{itemize}',
    '\\end{enumerate}',
    'Tail.',
  ].join('\n'),
  async (page, ok) => {
    await page.evaluate(() => {
      document.documentElement.setAttribute('data-palette', 'latex');
      const v = window.__chalkDebugView;
      v.dispatch({ selection: { anchor: v.state.doc.length } });
      v.contentDOM.blur();
    });
    await page.waitForTimeout(300);
    const m = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const doc = v.state.doc.toString();
      const left = (needle) => v.coordsAtPos(doc.indexOf(needle), 1).left;
      const alpha = doc.indexOf('Alpha');
      const firstTop = v.coordsAtPos(alpha, 1).top;
      let wrapLeft = null;
      for (let p = alpha; p < doc.indexOf('sure.'); p++) {
        const c = v.coordsAtPos(p, 1);
        if (c.top > firstTop + 4) {
          wrapLeft = c.left;
          break;
        }
      }
      return {
        item: left('Alpha'),
        wrap: wrapLeft,
        cont: left('Continuation'),
        nested: left('Nested'),
        intro: left('Intro'),
      };
    });
    ok('the item wraps', m.wrap !== null, JSON.stringify(m));
    ok('wrapped row starts at the item text', Math.abs(m.wrap - m.item) <= 1, `${m.wrap} vs ${m.item}`);
    ok('continuation line starts at the item text', Math.abs(m.cont - m.item) <= 1, `${m.cont} vs ${m.item}`);
    ok('the item is indented from the body', m.item > m.intro + 10, `${m.item} vs ${m.intro}`);
    ok('a nested item sits deeper', m.nested > m.item + 10, `${m.nested} vs ${m.item}`);
  },
  { width: 520, height: 700 },
);

// Typeset Markdown (the LaTeX theme, md-typeset.ts) lays lists out like the
// LaTeX ones: wrapped rows and continuation lines share the item text's edge
// in a proportional font.
await scenario(
  browser,
  'typeset md list: item text, wrapped rows and continuation lines share an edge',
  [
    '## Heading',
    '',
    '- Alpha first item, long enough that it wraps onto a second row in this narrow column for sure.',
    '  Continuation line of the same item.',
    '  - Nested bullet text.',
    '',
    'Tail.',
  ].join('\n'),
  async (page, ok) => {
    await page.evaluate(() => {
      document.documentElement.setAttribute('data-palette', 'latex');
      const v = window.__chalkDebugView;
      v.dispatch({ selection: { anchor: v.state.doc.length } });
      v.contentDOM.blur();
    });
    await page.waitForTimeout(300);
    const m = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const doc = v.state.doc.toString();
      const left = (needle) => v.coordsAtPos(doc.indexOf(needle), 1).left;
      const alpha = doc.indexOf('Alpha');
      const firstTop = v.coordsAtPos(alpha, 1).top;
      let wrapLeft = null;
      for (let p = alpha; p < doc.indexOf('sure.'); p++) {
        const c = v.coordsAtPos(p, 1);
        if (c.top > firstTop + 4) {
          wrapLeft = c.left;
          break;
        }
      }
      return {
        item: left('Alpha'),
        wrap: wrapLeft,
        cont: left('Continuation'),
        nested: left('Nested'),
        body: left('Tail'),
        heading: left('Heading'),
      };
    });
    ok('the item wraps', m.wrap !== null, JSON.stringify(m));
    ok('wrapped row starts at the item text', Math.abs(m.wrap - m.item) <= 1, `${m.wrap} vs ${m.item}`);
    ok('continuation line starts at the item text', Math.abs(m.cont - m.item) <= 1, `${m.cont} vs ${m.item}`);
    ok('the item is indented from the body', m.item > m.body + 10, `${m.item} vs ${m.body}`);
    ok('a nested item sits deeper', m.nested > m.item + 10, `${m.nested} vs ${m.item}`);
    // The `##` hangs in the gutter: heading text keeps the body's left edge.
    ok('heading text starts on the body column', Math.abs(m.heading - m.body) <= 1, `${m.heading} vs ${m.body}`);
  },
  { width: 520, height: 700 },
  'md',
  null,
  { markdownStyle: 'typeset' },
);

// A ```mermaid fence renders through the lazily injected mermaid.js under the
// page's real CSP. The diagram is a block widget, so the height map must agree
// with the DOM below it (the no-margins guardrail) and clicks there land.
await scenario(
  browser,
  'mermaid fence: lazy script renders, height map stays in sync',
  [
    'Intro paragraph.',
    '',
    '```mermaid',
    'flowchart TD',
    '  A[Start] --> B{Choice}',
    '  B -->|yes| C[Done]',
    '  B -->|no| A',
    '```',
    '',
    'After the diagram.',
    '',
    '```mermaid',
    'flowchart TD',
    '  broken -->',
    '```',
    '',
    'Tail line.',
  ].join('\n'),
  async (page, ok) => {
    const rendered = await page
      .waitForSelector('.cm-mermaid-diagram svg', { timeout: 15000 })
      .then(() => true, () => false);
    ok('the diagram renders', rendered);
    if (!rendered) return;
    await page.waitForSelector('.cm-mermaid-error:not([hidden])', { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(300);
    const m = await page.evaluate(() => {
      const v = window.__chalkDebugView;
      const doc = v.state.doc.toString();
      const box = document.querySelector('.cm-mermaid').getBoundingClientRect();
      const svg = document.querySelector('.cm-mermaid-diagram svg').getBoundingClientRect();
      const after = doc.indexOf('After the diagram.');
      // Line box against line box: a text range's top sits half a leading
      // lower, and by a different amount per engine.
      const line = [...v.contentDOM.querySelectorAll('.cm-line')].find((l) => l.textContent === 'After the diagram.');
      const domTop = line ? line.getBoundingClientRect().top : null;
      const scroller = document.querySelector('.cm-scroller');
      return {
        boxH: box.height,
        svgW: svg.width,
        contentW: v.contentDOM.getBoundingClientRect().width,
        domTop,
        lineBlockTop: v.lineBlockAt(after).top + v.documentTop,
        hScroll: scroller.scrollWidth > scroller.clientWidth + 1,
        errorText: document.querySelector('.cm-mermaid-error:not([hidden])')?.textContent ?? '',
        svgId: document.querySelector('.cm-mermaid-diagram svg').id,
      };
    });
    ok('the widget has height', m.boxH > 80, `${m.boxH}`);
    ok('the diagram fits the column', m.svgW <= m.contentW + 1, `${m.svgW} vs ${m.contentW}`);
    ok('no horizontal scroll', !m.hScroll);
    ok('height map agrees with the DOM below the diagram', Math.abs(m.lineBlockTop - m.domTop) <= 2, `${m.lineBlockTop} vs ${m.domTop}`);
    ok('the broken fence shows its parse error', m.errorText.length > 0);

    // A click on the line below the diagram lands on it.
    const r = await page.evaluate(FIND_TEXT, 'After the diagram.');
    await page.mouse.click(r.x + 3, r.y + r.h / 2);
    await page.waitForTimeout(100);
    const st = await page.evaluate(STATE);
    ok('click below the diagram lands on its line', st.line === 10, `line ${st.line}`);

    // A theme flip re-renders the diagram (a new mermaid render id).
    await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'));
    const rerendered = await page
      .waitForFunction((id) => document.querySelector('.cm-mermaid-diagram svg')?.id !== id, m.svgId, { timeout: 5000 })
      .then(() => true, () => false);
    ok('a theme change re-renders the diagram', rerendered);
  },
  { width: 760, height: 900 },
  'md',
);

await browser.close();

const known = xfails ? ` (${xfails} known-failing)` : '';
console.log(
  failures === 0 ? `\n[${tag}] ALL SCENARIOS PASSED${known}` : `\n[${tag}] ${failures} CHECK(S) FAILED${known}`,
);
process.exit(failures === 0 ? 0 : 1);
