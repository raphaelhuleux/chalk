#!/usr/bin/env node
/**
 * Records the README's GIFs into docs/images/ by typing into the built editor
 * bundle (web/dist) in headless Chromium, in the app's default Atom dark theme.
 *
 *   node scripts/screenshots/record-gifs.mjs            # build web/dist, record both
 *   node scripts/screenshots/record-gifs.mjs --no-build
 *
 * One screenshot per keystroke at 2x, then ffmpeg (on PATH) assembles them, so
 * the result is sharp and the timing exact. The page has no native chrome; the
 * editor itself is identical to the app's.
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
if (!process.argv.includes('--no-build')) {
  execFileSync(process.execPath, [resolve(root, 'web/build.mjs')], { stdio: 'inherit' });
}

/** A script is a list of steps: text to type, `{Tab}`-style keys, `{pause N}` in ms,
 *  or `{ caret: s }` to put the caret just after the first `s` in the document. */
const scenarios = [
  {
    out: 'live-preview.gif',
    language: 'md',
    snippets: false, // typed by hand: the point is the rendering, not the shortcuts
    text: '# Gaussian integral\n\n',
    steps: [
      'For $a > 0$, completing the square gives\n\n$$\n',
      '\\int_{-\\infty}^{\\infty} e^{-a x^2} \\, dx = \\sqrt{\\frac{\\pi}{a}}',
      '\n$$\n\nso the density $\\sqrt{a/\\pi}\\, e^{-a x^2}$ integrates to $1$.', '{pause 600}',
      // Back into the equation: its live preview tracks the edit below the source.
      { caret: 'e^{-a x^2' }, ' + b x', '{pause 300}',
      { caret: '\\sqrt{\\frac{\\pi}{a}}' }, ' \\, e^{b^2/4a}', '{pause 600}',
      { caret: 'integrates to $1$.' },
    ],
  },
  {
    out: 'snippets.gif',
    language: 'tex',
    snippets: true,
    text: '\\section{Law of large numbers}\n\n',
    steps: [
      // Snippets only fire in math the parser can see, so the prose is typed plainly.
      'If the $x_i$ are i.i.d. with mean $\\mu$, then', '{pause 400}',
      '\n', 'dm', '{pause 500}',
      'lim', 'n', '{Tab}', 'ooo', '{Tab}', ' 1/', 'n', '{Tab}',
      ' sum', '_', 'i=1', '{Tab}', '^n x', '_', 'i', '{Tab}', ' = ', ';m',
      '{pause 400}', '{ArrowDown}', '{End}', '\n\nalmost surely.',
    ],
  },
];

const W = 960, H = 400, CHAR_MS = 55;

const browser = await chromium.launch();
for (const sc of scenarios) {
  const frames = mkdtempSync(join(tmpdir(), 'chalk-gif-'));
  const page = await (await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 2 })).newPage();
  page.on('pageerror', (e) => console.error('page error:', String(e)));
  await page.addInitScript(() => {
    window.webkit = { messageHandlers: { chalkHost: { postMessage: () => {} } } };
  });
  await page.goto(pathToFileURL(resolve(root, 'web/dist/editor.html')).href + '?debug');
  await page.waitForFunction('() => window.__chalkHost !== undefined');

  // The app bundles IBM Plex Mono and registers it natively; the bare page has to load it.
  const fonts = resolve(root, 'mac/Chalk/Resources/fonts');
  await page.addStyleTag({
    content: [['Regular', 400], ['Medium', 500], ['SemiBold', 600]]
      .map(([n, w]) => `@font-face { font-family: "IBM Plex Mono"; font-weight: ${w};
        src: url("${pathToFileURL(resolve(fonts, `IBMPlexMono-${n}.ttf`)).href}"); }`)
      .join('\n'),
  });
  // What the Swift shell sets on the page: theme, palette and the chrome insets.
  await page.evaluate(() => {
    const el = document.documentElement;
    el.setAttribute('data-theme', 'dark');
    el.setAttribute('data-palette', 'atom');
    el.style.setProperty('--chalk-chrome-top', '44px');
    el.style.setProperty('--chalk-side-pad', '72px');
  });
  const send = (m) => page.evaluate((x) => window.__chalkHost.receive(x), m);
  if (sc.snippets) {
    await send({ type: 'hsnips', content: readFileSync(resolve(root, 'web/dist/latex.hsnips'), 'utf8') });
  }
  await send({ type: 'init', text: sc.text, language: sc.language });
  await page.waitForSelector('.cm-content');
  await page.evaluate(() => document.fonts.ready);
  await page.click('.cm-content');
  await page.keyboard.press('Meta+ArrowDown');
  await page.waitForTimeout(300);

  let n = 0;
  const list = [];
  const frame = async (seconds) => {
    const f = `f${String(n++).padStart(4, '0')}.png`;
    await page.screenshot({ path: join(frames, f) });
    list.push(`file '${f}'`, `duration ${seconds}`);
  };
  await frame(1.0);
  for (const step of sc.steps) {
    const key = typeof step === 'string' && /^\{(\w+)(?: (\d+))?\}$/.exec(step);
    if (typeof step === 'object') {
      await page.evaluate((s) => {
        const v = window.__chalkDebugView;
        const i = v.state.doc.toString().indexOf(s);
        if (i < 0) throw new Error(`caret target not found: ${s}`);
        v.dispatch({ selection: { anchor: i + s.length } });
        v.focus();
      }, step.caret);
      await page.waitForTimeout(300);
      await frame(0.6);
    } else if (key?.[1] === 'pause') {
      await page.waitForTimeout(Number(key[2]));
      await frame(Number(key[2]) / 1000);
    } else if (key) {
      await page.keyboard.press(key[1]);
      await frame(0.35);
    } else {
      for (const ch of step) {
        if (ch === '\n') await page.keyboard.press('Enter');
        else await page.keyboard.type(ch);
        await frame(CHAR_MS / 1000);
      }
    }
  }
  await page.waitForTimeout(400);
  await frame(3.0);
  list.push(list.at(-2)); // the concat demuxer ignores the last entry's duration
  writeFileSync(join(frames, 'list.txt'), list.join('\n') + '\n');

  const doc = await page.evaluate(() => window.__chalkDebugView.state.doc.toString());
  console.log(`${sc.out}: ${n} frames\n${doc}\n`);
  await page.context().close();

  execFileSync('ffmpeg', [
    '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', join(frames, 'list.txt'),
    '-vf', 'fps=20,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle',
    '-loop', '0', resolve(root, 'docs/images', sc.out),
  ]);
  rmSync(frames, { recursive: true, force: true });
}
await browser.close();
