#!/usr/bin/env node
/**
 * Layout-matrix snapshots of the writing surface.
 *
 *   node Tests/runner/snapshots.mjs --record   # write baselines
 *   node Tests/runner/snapshots.mjs            # compare against baselines
 *   node Tests/runner/snapshots.mjs --no-build
 *
 * One fixed document (inline math, a display equation, a very long equation,
 * a table, a code block) rendered across:
 *
 *   appearance   light | dark
 *   window mode  windowed | fullscreen
 *   sidebar      shown | hidden
 *   tab bar      shown | hidden
 *
 * 2 x 2 x 2 x 2 = 16 cases, all for the Mac app. Baselines in
 * Tests/__Snapshots__/, named `mac-*`.
 *
 * WHAT THIS SNAPSHOTS, AND WHAT IT DOES NOT
 * -----------------------------------------
 * It snapshots the EDITOR SURFACE, not the native chrome around it. There is
 * no picture of the real sidebar, the real tab strip, or a real macOS window
 * here.
 *
 * That is a deliberate limit, not an oversight. Chalk's document rendering is
 * a WKWebView, and the four matrix dimensions reach it only as four numbers
 * the Swift shell pushes across the HostPort: a theme attribute, a top inset,
 * a side padding, and an available width. This harness sets those four inputs
 * to the values each configuration actually produces, so what is compared is
 * the real rendering under real settings.
 *
 * The values are derived from mac/Chalk/App/ChalkMetrics.swift and
 * web/src/chalk-theme.css; each one is sourced in MATRIX below. Getting a
 * picture of the native chrome as well would need swift-snapshot-testing, a
 * WKWebView capture strategy, and new test hooks inside
 * RootSplitViewController, so it was not attempted here.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');
const snapshotDir = resolve(repoRoot, 'Tests/__Snapshots__');
const resultsDir = resolve(repoRoot, '.harness/results/snapshots');

const argv = process.argv.slice(2);
const RECORD = argv.includes('--record');

if (!argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], { stdio: 'inherit' });
}
if (!existsSync(dist)) {
  console.error(`missing ${dist} — run: pnpm web:build`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
//  The document
// ---------------------------------------------------------------------------
// Fixed, and deliberately contains one of each construct the brief names. The
// long equation is long enough to test horizontal containment, which is the
// thing `contain: inline-size` exists to hold (see the editor-core guardrails).
const DOCUMENT = [
  '# Least squares',
  '',
  'The estimator $\\hat\\beta = (X\'X)^{-1}X\'y$ is unbiased when $E[\\varepsilon \\mid X] = 0$.',
  '',
  '$$',
  '\\hat\\beta = \\left( \\sum_{t=1}^{T} x_t x_t\' \\right)^{-1} \\sum_{t=1}^{T} x_t y_t',
  '$$',
  '',
  'A wider one, to check that a long formula stays inside the text column:',
  '',
  '$$',
  '\\mathcal{L}(\\theta) = -\\frac{T}{2}\\log(2\\pi) - \\frac{T}{2}\\log(\\sigma^2) - \\frac{1}{2\\sigma^2}\\sum_{t=1}^{T}(y_t - x_t\'\\beta)^2 + \\lambda\\sum_{j=1}^{k}|\\beta_j| + \\gamma\\sum_{j=1}^{k}\\beta_j^2',
  '$$',
  '',
  '| Specification | Estimate | Std. error |',
  '| --- | --- | --- |',
  '| Baseline | 0.412 | 0.031 |',
  '| With controls | 0.388 | 0.029 |',
  '| Full sample | 0.401 | 0.024 |',
  '',
  '```python',
  'def ols(X, y):',
  '    return np.linalg.solve(X.T @ X, X.T @ y)',
  '```',
  '',
  'Closing prose so the last block is not flush against the bottom edge.',
  '',
].join('\n');

// ---------------------------------------------------------------------------
//  The matrix
// ---------------------------------------------------------------------------
//
// Sources for every number below:
//
//   ChalkMetrics.editorRestingPad = 27          one editor line (17px x 1.6)
//   ChalkMetrics.headerHeight     = 44 / 0.77   the tab band (Catalyst scales
//                                   = 57.14      the UIKit idiom to 77%, so
//                                                spec points are inverse-scaled)
//   editor side padding            = 20          the web default from
//                                                chalk-theme.css
//   ChalkMetrics.sidebarWidth      = 258 / 0.77 = 335
//
// Chrome top inset is `band + editorRestingPad` when the tab bar is shown.
// With the tab bar hidden the band collapses to the system safe-area inset,
// which this harness does not model: the hidden case uses the resting pad
// alone, which is exact on the Mac.
const MAC = { sidePad: 20, band: 44 / 0.77, sidebar: 258 / 0.77,
              windowed: [1200, 800], fullscreen: [1728, 1080] };

const RESTING_PAD = 27;

const CASES = [];
for (const appearance of ['light', 'dark']) {
  for (const windowMode of ['windowed', 'fullscreen']) {
    for (const sidebar of ['shown', 'hidden']) {
      for (const tabBar of ['shown', 'hidden']) {
        const [w, h] = MAC[windowMode];
        CASES.push({
          name: `mac-${appearance}-${windowMode}-sidebar-${sidebar}-tabbar-${tabBar}`,
          width: Math.round(sidebar === 'shown' ? w - MAC.sidebar : w),
          height: h,
          chromeTop: Math.round(tabBar === 'shown' ? MAC.band + RESTING_PAD : RESTING_PAD),
          sidePad: MAC.sidePad,
          theme: appearance,
        });
      }
    }
  }
}

// ---------------------------------------------------------------------------
//  Capture
// ---------------------------------------------------------------------------

async function capture(browser, c) {
  const page = await browser.newPage({ viewport: { width: c.width, height: c.height } });
  await page.goto(pathToFileURL(dist).href + '?debug');
  await page.waitForFunction('() => window.__chalkHost !== undefined');
  await page.evaluate((msg) => window.__chalkHost.receive(msg), {
    type: 'init', text: DOCUMENT, language: 'md',
  });
  await page.waitForSelector('.cm-content');

  // The four inputs the Swift shell actually pushes for this configuration.
  await page.evaluate(({ theme, chromeTop, sidePad }) => {
    document.documentElement.dataset.theme = theme;
    document.documentElement.style.setProperty('--chalk-chrome-top', chromeTop + 'px');
    document.documentElement.style.setProperty('--chalk-side-pad', sidePad + 'px');
  }, c);

  // Park the caret at the end of the document. Live preview reveals the source
  // of whatever construct the caret sits in (bold, italic, math, links), and
  // the caret defaults to offset 0, so a baseline could otherwise record a
  // reveal state as if it were the document's resting rendering.
  //
  // Note this is NOT why the heading keeps its "#": markdown markers stay
  // visible by design in this editor and headings are colour-only, which
  // chalk-theme.css states outright. The parking guards the constructs that do
  // conceal.
  await page.evaluate(() => {
    const view = window.__chalkDebugView;
    view.dispatch({ selection: { anchor: view.state.doc.length } });
  });

  // KaTeX renders asynchronously; wait for the formulas rather than a timeout,
  // then settle for fonts. A snapshot taken mid-render is a baseline that
  // fails at random later.
  await page.waitForFunction('() => document.querySelectorAll(".katex").length >= 3');
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(350);

  const png = await page.screenshot({ animations: 'disabled', caret: 'hide' });
  await page.close();
  return png;
}

// ---------------------------------------------------------------------------
//  Main
// ---------------------------------------------------------------------------

mkdirSync(snapshotDir, { recursive: true });
if (!RECORD) mkdirSync(resultsDir, { recursive: true });

const browser = await chromium.launch();
let recorded = 0;
let matched = 0;
const mismatched = [];
const missing = [];

console.log(`layout matrix: ${CASES.length} cases${RECORD ? ' (recording)' : ''}\n`);

for (const c of CASES) {
  const file = join(snapshotDir, `${c.name}.png`);
  const png = await capture(browser, c);

  if (RECORD) {
    writeFileSync(file, png);
    console.log(`rec  ${c.name}  ${(png.length / 1024).toFixed(0)}KB  ${c.width}x${c.height} top=${c.chromeTop} pad=${c.sidePad}`);
    recorded++;
    continue;
  }

  if (!existsSync(file)) {
    console.log(`MISS ${c.name}  no baseline; record with --record`);
    missing.push(c.name);
    continue;
  }
  const baseline = readFileSync(file);
  if (baseline.equals(png)) {
    console.log(`ok   ${c.name}`);
    matched++;
  } else {
    const actual = join(resultsDir, `${c.name}.actual.png`);
    writeFileSync(actual, png);
    console.log(`FAIL ${c.name}`);
    console.log(`  expected: Tests/__Snapshots__/${c.name}.png (${baseline.length} bytes)`);
    console.log(`  actual:   .harness/results/snapshots/${c.name}.actual.png (${png.length} bytes)`);
    mismatched.push(c.name);
  }
}

await browser.close();

if (RECORD) {
  console.log(`\nrecorded ${recorded} baselines in Tests/__Snapshots__/`);
  process.exit(0);
}

console.log(`\n${matched} matched, ${mismatched.length} changed, ${missing.length} missing`);
if (mismatched.length || missing.length) {
  console.log('\nA changed snapshot is either a rendering regression (fix the rendering)');
  console.log('or an intended visual change (a person re-records the baseline).');
  console.log('Never re-record to make this pass.');
  process.exit(1);
}
process.exit(0);
