#!/usr/bin/env node
/**
 * Interactive playground for the BUILT web bundle (web/dist), in a real
 * Chromium window you can type in — the manual sibling of run.mjs, which
 * drives the same page headlessly and asserts.
 *
 * Use it to look at rendering that no assertion captures well: how a Beamer
 * frame card sits on the page, whether a reveal reflows the paragraph, what
 * the caret does inside a snippet. Nothing here is a test.
 *
 * Run from the repo root:
 *   node Tests/browser/open.mjs           # Welcome.md
 *   node Tests/browser/open.mjs --tex     # Welcome.tex
 *   node Tests/browser/open.mjs --file notes.md
 *   ... --build          rebuild web/dist first (implied if it is missing)
 *   ... --mode typewriter | focus | normal
 *   ... --write          with --file: flush the buffered edits back on exit
 *
 * `?debug` gates `window.__chalkDebugView` (mount.ts), so the DevTools console
 * can reach the live EditorView: __chalkDebugView.state.doc.toString().
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const dist = resolve(repoRoot, 'web/dist/editor.html');
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n) => (argv.indexOf(n) >= 0 ? argv[argv.indexOf(n) + 1] : null);

if (flag('--build') || !existsSync(dist)) {
  execFileSync(process.execPath, [resolve(repoRoot, 'web/build.mjs')], { stdio: 'inherit' });
}

/** Pull a Swift raw literal (`#"""` … `"""#`) and undo the indentation Swift
 *  strips at runtime — same reach-across the welcome-samples test makes, so
 *  the playground opens the bytes the app actually seeds. */
function swiftRawLiteral(source, name) {
  const start = new RegExp(`static let ${name} = #"""\\n`).exec(source);
  if (!start) throw new Error(`no raw literal named ${name}`);
  const body = source.slice(start.index + start[0].length);
  const end = body.indexOf('"""#');
  const indent = /([ \t]*)"""#/.exec(body.slice(end - 40, end + 4))?.[1] ?? '';
  return body
    .slice(0, end)
    .split('\n')
    .map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l))
    .join('\n')
    .replace(/\n[ \t]*$/, '\n');
}

const file = opt('--file');
const target = file ? resolve(process.cwd(), file) : null;
const language = target ? (extname(target) === '.tex' ? 'tex' : 'md') : flag('--tex') ? 'tex' : 'md';
const text = target
  ? readFileSync(target, 'utf8')
  : swiftRawLiteral(
      readFileSync(resolve(repoRoot, 'mac/Chalk/Document/SampleContent.swift'), 'utf8'),
      language === 'tex' ? 'welcomeTeX' : 'welcomeMarkdown',
    );

const browser = await chromium.launch({ headless: false, args: ['--window-size=1120,940'] });
const page = await browser.newPage({ viewport: null });
page.on('pageerror', (e) => console.error('page error:', String(e)));
page.on('console', (m) => (m.type() === 'error' ? console.error('console:', m.text()) : null));

// Stand in for the native bridge. native-host.ts optional-chains
// `webkit?.messageHandlers?.chalkHost`, so without this the editor→host half
// of the protocol is silently dropped and edits are unobservable.
let buffered = text;
await page.exposeFunction('__hostSend', (json) => {
  const m = JSON.parse(json);
  if (m.type === 'edit') buffered = m.text;
  else if (m.type === 'open-external') console.log('open-external →', m.url);
});
await page.addInitScript(() => {
  window.webkit = {
    messageHandlers: {
      chalkHost: {
        postMessage: (m) => {
          try {
            window.__hostSend(JSON.stringify(m));
          } catch {}
        },
      },
    },
  };
});

await page.goto(pathToFileURL(dist).href + '?debug');
await page.waitForFunction('() => window.__chalkHost !== undefined');

const send = (msg) => page.evaluate((m) => window.__chalkHost.receive(m), msg);
const snippets = resolve(repoRoot, 'web/dist/latex.hsnips');
if (existsSync(snippets)) await send({ type: 'hsnips', content: readFileSync(snippets, 'utf8') });
await send({ type: 'init', text, language });
if (opt('--mode')) await send({ type: 'editor-config', config: { editingMode: opt('--mode') } });
await page.waitForSelector('.cm-content');

console.log(`\nopen: ${target ?? `Welcome.${language === 'tex' ? 'tex' : 'md'} (sample)`}  [${language}]`);
console.log('window is live — close it or press Ctrl-C to stop.');
console.log('DevTools console: __chalkDebugView.state.doc.toString()\n');

await new Promise((done) => {
  browser.on('disconnected', done);
  process.on('SIGINT', done);
});

if (target && flag('--write') && buffered !== text) {
  writeFileSync(target, buffered);
  console.log(`wrote ${buffered.length} chars back to ${target}`);
}
await browser.close().catch(() => {});
process.exit(0);
