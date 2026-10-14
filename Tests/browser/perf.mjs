#!/usr/bin/env node
/**
 * Browser performance harness for the editor hot paths.
 *
 * Companion to run.mjs (same bootstrap: built web/dist bundle, headless
 * Chromium, `?debug`-gated `window.__chalkDebugView`). Where run.mjs pins
 * behavior, this one measures cost: it seeds a ~200KB .tex document, drives
 * real keyboard input under 4x CPU throttling, and reports per-scenario
 *   - rAF frame-duration mean/p95 (what typing latency feels like), and
 *   - CDP Performance metrics deltas (RecalcStyleCount / LayoutCount per
 *     keypress — the direct probe for forced style/layout work in the
 *     keystroke path, e.g. scrollMargins readers).
 *
 * Run from the repo root:
 *   node Tests/browser/perf.mjs            # builds web/dist first
 *   node Tests/browser/perf.mjs --no-build # reuse the bundle
 *
 * Prints one JSON object to stdout. Compare runs with the same flags on the
 * same machine only; absolute numbers are not portable.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');

if (!process.argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], {
    stdio: 'inherit',
  });
}
if (!existsSync(dist)) {
  console.error(`missing ${dist} — run: pnpm web:build`);
  process.exit(1);
}

const KEYS = 100;
const CPU_THROTTLE = 4;

// ~200KB: the real showcase doc, concatenated. Keeps math/callout/section
// density realistic instead of synthetic prose.
const seedDoc = Array(10)
  .fill(readFileSync(resolve(repoRoot, 'test-docs/least-squares.tex'), 'utf8'))
  .join('\n');

// The real bundled snippet set: without it the per-keystroke snippet loop
// (~230 automatic snippets in .tex) is absent and the measurement flatters
// the engine. The native host sends this right after init; mirror that.
const hsnipsContent = readFileSync(
  resolve(repoRoot, 'packages/editor-core/assets/latex.hsnips'),
  'utf8',
);

const metricsOfInterest = [
  'RecalcStyleCount',
  'LayoutCount',
  'RecalcStyleDuration',
  'LayoutDuration',
  'ScriptDuration',
];

function summarizeFrames(samples) {
  // Drop the first 5 frames (settle) and idle frames >250ms (inter-key gaps
  // when the queue drains — not editor work).
  const s = samples.slice(5).filter((d) => d < 250).sort((a, b) => a - b);
  if (s.length === 0) return { frames: 0, mean: null, p95: null, max: null };
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  return {
    frames: s.length,
    mean: +mean.toFixed(2),
    p95: +s[Math.floor(s.length * 0.95)].toFixed(2),
    max: +s[s.length - 1].toFixed(2),
  };
}

async function getMetrics(cdp) {
  const { metrics } = await cdp.send('Performance.getMetrics');
  const out = {};
  for (const m of metrics) if (metricsOfInterest.includes(m.name)) out[m.name] = m.value;
  return out;
}

/**
 * caretProbe runs in the page and returns a document offset for the caret:
 *  - 'prose': end of the first long prose line,
 *  - 'math' : inside the body of the first equation environment.
 */
const CARET_PROBE = (kind) => {
  const doc = window.__chalkDebugView.state.doc.toString();
  if (kind === 'math') {
    const env = doc.indexOf('\\begin{equation}');
    const bodyLine = doc.indexOf('\n', env) + 1;
    const lineEnd = doc.indexOf('\n', bodyLine);
    return lineEnd - 2; // inside the equation body, before the line's tail
  }
  // Prose: caret at the end of the first line longer than 60 chars that
  // contains no backslash (plain text).
  let from = 0;
  for (;;) {
    const nl = doc.indexOf('\n', from);
    const line = doc.slice(from, nl < 0 ? doc.length : nl);
    if (line.length > 60 && !line.includes('\\')) return from + line.length;
    if (nl < 0) return doc.length;
    from = nl + 1;
  }
};

async function scenario(browser, name, drive) {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e)));
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Performance.enable');
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: CPU_THROTTLE });

  await page.goto(pathToFileURL(dist).href + '?debug');
  await page.waitForFunction('() => window.__chalkHost !== undefined');
  await page.evaluate((msg) => window.__chalkHost.receive(msg), {
    type: 'init',
    text: seedDoc,
    language: 'tex',
  });
  await page.evaluate((msg) => window.__chalkHost.receive(msg), {
    type: 'hsnips',
    content: hsnipsContent,
  });
  // The native shell publishes the chrome band inset as an inline style on
  // documentElement; set it so the chromeTopMargin scrollMargins path runs
  // with a real value like in the app.
  await page.evaluate(() => {
    document.documentElement.style.setProperty('--chalk-chrome-top', '52px');
  });
  await page.waitForSelector('.cm-content');
  await page.waitForTimeout(1500); // initial parse + decoration settle

  // rAF frame sampler.
  await page.evaluate(() => {
    window.__frames = [];
    window.__sampling = true;
    let last = performance.now();
    const loop = () => {
      const now = performance.now();
      window.__frames.push(now - last);
      last = now;
      if (window.__sampling) requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  });

  const before = await getMetrics(cdp);
  await drive(page);
  await page.waitForTimeout(300); // let trailing debounced work land
  const after = await getMetrics(cdp);

  const frames = await page.evaluate(() => {
    window.__sampling = false;
    return window.__frames;
  });

  const perKey = {};
  for (const k of ['RecalcStyleCount', 'LayoutCount'])
    perKey[k] = +((after[k] - before[k]) / KEYS).toFixed(2);
  const durations = {};
  for (const k of ['RecalcStyleDuration', 'LayoutDuration', 'ScriptDuration'])
    durations[k] = +(((after[k] - before[k]) * 1000) / KEYS).toFixed(2); // ms/key

  const result = {
    name,
    frame: summarizeFrames(frames),
    perKey,
    msPerKey: durations,
    pageErrors: errors,
  };
  await page.close();
  return result;
}

const placeCaret = (page, kind) =>
  page.evaluate((k) => {
    const CARET_PROBE = (kind) => {
      const doc = window.__chalkDebugView.state.doc.toString();
      if (kind === 'math') {
        const env = doc.indexOf('\\begin{equation}');
        const bodyLine = doc.indexOf('\n', env) + 1;
        const lineEnd = doc.indexOf('\n', bodyLine);
        return lineEnd - 2;
      }
      let from = 0;
      for (;;) {
        const nl = doc.indexOf('\n', from);
        const line = doc.slice(from, nl < 0 ? doc.length : nl);
        if (line.length > 60 && !line.includes('\\')) return from + line.length;
        if (nl < 0) return doc.length;
        from = nl + 1;
      }
    };
    const v = window.__chalkDebugView;
    v.dispatch({ selection: { anchor: CARET_PROBE(k) }, scrollIntoView: true });
    v.focus();
  }, kind);

const browser = await chromium.launch();
const results = [];

results.push(
  await scenario(browser, `prose typing (${KEYS} keys)`, async (page) => {
    await placeCaret(page, 'prose');
    await page.keyboard.type('x'.repeat(KEYS), { delay: 15 });
  }),
);

results.push(
  await scenario(browser, `math typing (${KEYS} keys)`, async (page) => {
    await placeCaret(page, 'math');
    // Digits: valid in math, low risk of triggering snippet expansion noise.
    await page.keyboard.type('1'.repeat(KEYS), { delay: 15 });
  }),
);

results.push(
  await scenario(browser, `arrow-down hold (${KEYS} presses)`, async (page) => {
    await placeCaret(page, 'prose');
    for (let i = 0; i < KEYS; i++) {
      await page.keyboard.press('ArrowDown', { delay: 5 });
      await page.waitForTimeout(10);
    }
  }),
);

await browser.close();

const report = {
  date: new Date().toISOString(),
  docBytes: seedDoc.length,
  cpuThrottle: CPU_THROTTLE,
  keysPerScenario: KEYS,
  scenarios: results,
};
console.log(JSON.stringify(report, null, 2));
const failed = results.some((r) => r.pageErrors.length > 0);
process.exit(failed ? 1 : 0);
