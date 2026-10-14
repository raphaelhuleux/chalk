#!/usr/bin/env node
/**
 * One benchmark iteration. Prints a single JSON object to stdout.
 *
 *   node Tests/runner/bench.mjs [--no-build]
 *
 * scripts/bench.sh runs this five times and takes the median of each metric,
 * because a single run of any of these numbers is noise.
 *
 * WHAT IS BEING MEASURED, AND WHAT IS NOT
 * ---------------------------------------
 * Chalk's editor is CodeMirror 6 in a WKWebView, so every metric here is taken
 * inside the web engine, driving the same bundle the app ships. That is where
 * typing latency, math rendering and scroll cost actually live.
 *
 * It is NOT the whole app. The Swift shell's own memory, and the WKWebView
 * process's resident size, are outside a page's reach. Headless Chromium is
 * also not WebKit: treat these as a regression signal on this machine, not as
 * absolute numbers. Compare runs with the same flags on the same machine.
 *
 * Metrics
 *   key_to_model_p95_ms  95th percentile keydown-to-state-updated latency,
 *                        typing into a 5000 line document under CPU throttling.
 *   render_200_math_ms   init a document of 200 display equations and scroll it
 *                        end to end until every one has rendered.
 *   idle_cpu_percent     renderer task time over a 10 second window with no
 *                        input, as a percentage of wall clock.
 *   peak_heap_mb         peak JS heap while opening and scrolling the large file.
 */
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');

if (!process.argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], { stdio: 'inherit' });
}
if (!existsSync(dist)) {
  console.error(`missing ${dist} — run: pnpm web:build`);
  process.exit(1);
}

const CPU_THROTTLE = 4; // same factor as Tests/browser/perf.mjs, so the two compare
const IDLE_SECONDS = 10;
const TYPE_KEYS = 60;
const MATH_BLOCKS = 200;

/** A .tex document with realistic prose and periodic structure. Parameterised
 *  by length so the SCALING of typing cost is measurable, not just its value
 *  at one size: the failure mode this bench exists to catch is per-keystroke
 *  work that is linear in document length, and a single absolute number
 *  cannot see it (2026-08-26). */
function bigDocument(lineCount = 5000) {
  const lines = [];
  for (let i = 0; i < lineCount; i++) {
    if (i % 50 === 0) lines.push(`\\section{Section ${i / 50}}`);
    else if (i % 17 === 0) lines.push(`The estimator $\\hat\\beta_{${i}}$ is consistent under assumption ${i % 7}.`);
    else lines.push(`Line ${i}: the quick brown fox jumps over the lazy dog, repeatedly and without complaint.`);
  }
  return lines.join('\n');
}

/** A markdown document shaped like markdown: ATX headings, blank lines
 *  between paragraphs, inline math. Deliberately NOT the .tex document with
 *  the language switched -- see `longParagraphDocument`. */
function markdownDocument(lineCount = 5000) {
  const lines = [];
  for (let i = 0; i < lineCount; i++) {
    if (i % 50 === 0) {
      lines.push(`## Section ${i / 50}`);
      lines.push('');
    } else if (i % 17 === 0) {
      lines.push(`The estimator $\\hat\\beta_{${i}}$ is consistent under assumption ${i % 7}.`);
    } else {
      lines.push(`Line ${i}: the quick brown fox jumps over the lazy dog.`);
      if (i % 8 === 7) lines.push('');
    }
  }
  return lines.join('\n');
}

/**
 * The same prose as one unbroken paragraph -- no blank line anywhere.
 *
 * Lezer re-parses the enclosing LEAF BLOCK's inline content on every
 * keystroke, so markdown typing cost tracks PARAGRAPH length, not document
 * length. Measured 2026-08-26 on identical prose at 5000 lines: 103.6ms per
 * keystroke as one paragraph against 10.8ms with a blank line every 50. That
 * cliff is reachable by ordinary writing (a long run of one-sentence lines,
 * a list with no blank lines) and nothing watched it, because the bench only
 * ever measured `.tex`.
 */
function longParagraphDocument(lineCount = 5000) {
  const lines = [];
  for (let i = 0; i < lineCount; i++) {
    lines.push(`Line ${i}: the quick brown fox jumps over the lazy dog, repeatedly.`);
  }
  return lines.join('\n');
}

/** 200 display equations, each non-trivial enough that KaTeX does real work. */
function mathDocument() {
  const blocks = [];
  for (let i = 0; i < MATH_BLOCKS; i++) {
    blocks.push(`Paragraph ${i} introducing the result below.`);
    blocks.push('');
    blocks.push('\\begin{equation}');
    blocks.push(`  \\hat\\beta_{${i}} = \\left( \\sum_{t=1}^{T} x_t x_t' \\right)^{-1} \\sum_{t=1}^{T} x_t y_t + \\frac{\\partial \\mathcal{L}}{\\partial \\theta_{${i}}}`);
    blocks.push('\\end{equation}');
    blocks.push('');
  }
  return blocks.join('\n');
}

const browser = await chromium.launch();

async function newEditor(doc, language) {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Performance.enable');
  await page.goto(pathToFileURL(dist).href + '?debug');
  await page.waitForFunction('() => window.__chalkHost !== undefined');
  const initAt = Date.now();
  await page.evaluate((msg) => window.__chalkHost.receive(msg), { type: 'init', text: doc, language });
  await page.waitForSelector('.cm-content');
  return { page, cdp, initAt };
}

const metricValue = (metrics, name) => metrics.metrics.find((m) => m.name === name)?.value ?? 0;

// ---------------------------------------------------------------------------
// 1. key-to-model p95 on a 5000 line document
// ---------------------------------------------------------------------------
async function keyToModel(lineCount = 5000, language = 'tex', doc = null) {
  const { page, cdp } = await newEditor(doc ?? bigDocument(lineCount), language);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: CPU_THROTTLE });
  await page.waitForTimeout(600);

  // Timestamp each keydown, then the dispatch it causes. `dispatch` is a
  // prototype method, so assigning here shadows it for this instance only and
  // measures the real path: browser input pipeline, CodeMirror transaction,
  // state update. Reading the DOM afterwards would measure paint instead.
  await page.evaluate(() => {
    const view = window.__chalkDebugView;
    window.__bench = { samples: [], keyAt: null };
    view.contentDOM.addEventListener('keydown', () => { window.__bench.keyAt = performance.now(); }, true);
    const original = view.dispatch.bind(view);
    view.dispatch = (...args) => {
      const result = original(...args);
      if (window.__bench.keyAt !== null) {
        window.__bench.samples.push(performance.now() - window.__bench.keyAt);
        window.__bench.keyAt = null;
      }
      return result;
    };
  });

  // Type in the middle of the document, not at the top: the interesting cost
  // is with a populated height map above and below the caret.
  await page.evaluate(() => {
    const view = window.__chalkDebugView;
    const line = view.state.doc.line(Math.floor(view.state.doc.lines / 2));
    view.dispatch({ selection: { anchor: line.to }, scrollIntoView: true });
    view.focus();
  });
  // Let the language parser catch up with the jump before sampling. Markdown
  // is parsed incrementally by Lezer, so landing the caret 2500 lines away
  // leaves real parse work queued; sampling at 400ms measured that backlog and
  // reported ~112ms/key where the settled cost is ~8ms (2026-08-26). Typing
  // into a freshly-revealed region IS slow for a moment, but that is a
  // different metric from steady-state typing cost, and mixing them makes this
  // one unreadable.
  await page.waitForTimeout(2500);

  for (let i = 0; i < TYPE_KEYS; i++) {
    await page.keyboard.type('x');
    await page.waitForTimeout(12);
  }

  const samples = await page.evaluate(() => window.__bench.samples);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
  await page.close();

  if (samples.length < TYPE_KEYS / 2) {
    throw new Error(`only ${samples.length} of ${TYPE_KEYS} keystrokes reached the model`);
  }
  const sorted = samples.slice().sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
}

// ---------------------------------------------------------------------------
// 2. full render pass over 200 math blocks
// ---------------------------------------------------------------------------
async function renderMath() {
  const { page, initAt } = await newEditor(mathDocument(), 'tex');
  // CodeMirror virtualizes the viewport, so "render every block" means walking
  // the document. Scroll in viewport-sized steps until the rendered count
  // stops growing and every block has been through KaTeX.
  await page.evaluate(async (expected) => {
    const view = window.__chalkDebugView;
    const scroller = view.scrollDOM;
    const seen = new Set();
    let guard = 0;
    while (seen.size < expected && guard++ < 400) {
      // Key on the rendered text alone. Including the element's position
      // would count one equation once per scroll offset, inflating the set
      // and ending the walk long before the document bottom. Every equation
      // carries its own index, so the text is already unique.
      for (const el of document.querySelectorAll('.katex')) {
        seen.add(el.textContent.slice(0, 64));
      }
      if (scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2) break;
      scroller.scrollTop += Math.floor(scroller.clientHeight * 0.8);
      await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    }
  }, MATH_BLOCKS);
  const elapsed = Date.now() - initAt;
  await page.close();
  return elapsed;
}

// ---------------------------------------------------------------------------
// 3. idle CPU over 10 seconds
// ---------------------------------------------------------------------------
async function idleCpu() {
  const { page, cdp } = await newEditor(bigDocument(), 'tex');
  await page.waitForTimeout(1500); // let mount settle; this is idle, not startup
  const before = await cdp.send('Performance.getMetrics');
  const wallBefore = Date.now();
  await page.waitForTimeout(IDLE_SECONDS * 1000);
  const after = await cdp.send('Performance.getMetrics');
  const wallElapsed = (Date.now() - wallBefore) / 1000;
  const taskDelta = metricValue(after, 'TaskDuration') - metricValue(before, 'TaskDuration');
  await page.close();
  return (taskDelta / wallElapsed) * 100;
}

// ---------------------------------------------------------------------------
// 4. peak heap while opening and scrolling a large file
// ---------------------------------------------------------------------------
async function peakHeap() {
  const { page, cdp } = await newEditor(bigDocument(), 'tex');
  let peak = 0;
  const sample = async () => {
    const m = await cdp.send('Performance.getMetrics');
    peak = Math.max(peak, metricValue(m, 'JSHeapUsedSize'));
  };
  await sample();
  for (let step = 0; step < 12; step++) {
    await page.evaluate(() => {
      const s = window.__chalkDebugView.scrollDOM;
      s.scrollTop += s.clientHeight * 4;
    });
    await page.waitForTimeout(120);
    await sample();
  }
  await page.close();
  return peak / (1024 * 1024);
}

// ---------------------------------------------------------------------------
// 5. tex scroll frame cost — widget DOM creation as math enters the viewport.
//    Markdown scrolls a flat 17ms where tex was 25ms (2026-08-26) and nothing
//    watched the difference.
// ---------------------------------------------------------------------------
async function texScrollP95() {
  const { page, cdp } = await newEditor(bigDocument(), 'tex');
  await page.waitForTimeout(1500);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: CPU_THROTTLE });
  await page.waitForTimeout(200);
  const p95 = await page.evaluate(async () => {
    const sc = document.querySelector('.cm-scroller');
    const frames = [];
    let last = performance.now();
    let n = 0;
    await new Promise((done) => {
      function step() {
        const now = performance.now();
        frames.push(now - last);
        last = now;
        sc.scrollTop += 220;
        if (++n < 90) requestAnimationFrame(step);
        else done();
      }
      requestAnimationFrame(step);
    });
    frames.shift();
    frames.sort((a, b) => a - b);
    return frames[Math.floor(frames.length * 0.95)];
  });
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 1 });
  await page.close();
  return p95;
}

const texSmall = await keyToModel(500);
const texLarge = await keyToModel(5000);

const result = {
  key_to_model_p95_ms: texLarge,
  key_to_model_500_p95_ms: texSmall,
  // The ratio IS the gate for scaling. Per-keystroke work that reads the whole
  // document shows up here long before it shows up as an absolute number a
  // fast machine can absorb.
  key_to_model_scaling: texLarge / texSmall,
  md_key_to_model_p95_ms: await keyToModel(5000, 'md', markdownDocument()),
  // The paragraph-length cliff, watched on purpose — see longParagraphDocument.
  md_long_paragraph_p95_ms: await keyToModel(5000, 'md', longParagraphDocument()),
  tex_scroll_p95_ms: await texScrollP95(),
  render_200_math_ms: await renderMath(),
  idle_cpu_percent: await idleCpu(),
  peak_heap_mb: await peakHeap(),
};

await browser.close();

for (const k of Object.keys(result)) result[k] = Math.round(result[k] * 100) / 100;
console.log(JSON.stringify(result));
