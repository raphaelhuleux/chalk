#!/usr/bin/env node
// Guardrail check: the diagnostics ring must not be able to carry user data.
//
// Chalk's bug reports attach a DiagnosticsRing render. That payload is safe
// only because `record()` accepts no free text at any arity, so a file name
// cannot be passed through it. That property is easy to lose: someone adds a
// `String` parameter "just for this one case" and every future call site
// inherits the hole.
//
// This is not hypothetical. SceneDelegate.logState built a String carrying
// `activeTab.url.lastPathComponent` and logged it `privacy: .public`, so the
// open document's file name went to the unified log unredacted in release
// builds — in the one file written *as* diagnostics. Comments do not fail
// builds; this does.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const problems = [];

// --- Rule 1: the ingress signature accepts no free text. ---------------------
const ringPath = 'mac/ChalkKit/Sources/ChalkKit/DiagnosticsRing.swift';
const ring = readFileSync(join(root, ringPath), 'utf8');

const signature = ring.match(/public func record\(([\s\S]*?)\)\s*\{/);
if (!signature) {
  problems.push(`${ringPath}: could not find 'public func record(' — did the ingress get renamed?`);
} else {
  const banned = ['String', 'CustomStringConvertible', 'URL', 'Data', 'Any'];
  for (const type of banned) {
    if (new RegExp(`:\\s*${type}\\b`).test(signature[1])) {
      problems.push(
        `${ringPath}: record() takes a ${type} parameter. The ring is safe to `
        + `email only because a caller cannot express a file name.`);
    }
  }
}

// The event type must not declare a free-text field either. (A unit test
// asserts this via Mirror too; this catches it before the test suite runs.)
const eventBody = ring.match(/public struct DiagEvent[\s\S]*?\n\}/);
if (eventBody) {
  for (const type of ['String', 'URL', 'Data']) {
    if (new RegExp(`let \\w+:\\s*${type}\\b`).test(eventBody[0])) {
      problems.push(`${ringPath}: DiagEvent declares a ${type} field.`);
    }
  }
}

// --- Rule 2: no call site smuggles user data in. -----------------------------
// Even with an Int-only signature, `Diagnostics.foo(Int(path.hashValue))` or a
// wrapper taking a String would defeat the point. Flag the known carriers.
const CARRIERS = [
  'lastPathComponent', '.path', '.absoluteString', 'localizedDescription',
  '.relativePath', 'displayName', '.userInfo',
];

const swiftFiles = [];
(function walk(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      if (entry === 'Resources' || entry === 'build') continue;
      walk(full);
    } else if (entry.endsWith('.swift')) {
      swiftFiles.push(full);
    }
  }
})(join(root, 'mac/Chalk'));

for (const file of swiftFiles) {
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    if (!/\bDiagnostics\.\w+\(/.test(line)) return;
    const args = line.slice(line.indexOf('('));
    if (/"/.test(args) || /\\\(/.test(args)) {
      problems.push(
        `${relative(root, file)}:${i + 1}: a Diagnostics call carries a string `
        + `literal or interpolation:\n      ${line.trim()}`);
    }
    for (const carrier of CARRIERS) {
      if (args.includes(carrier)) {
        problems.push(
          `${relative(root, file)}:${i + 1}: a Diagnostics call reads ${carrier}, `
          + `which carries user data:\n      ${line.trim()}`);
      }
    }
  });
}

// --- Rule 3: no log line marks a user-data carrier as public. ----------------
// os_log decides redaction per interpolation, so redacting the file name in one
// segment and interpolating `error.localizedDescription` as .public in the next
// hands it straight back. Measured, not assumed: a failed write of
// `secret-thesis-chapter.md` produces "You don't have permission to save the
// file "secret-thesis-chapter.md" in the folder "...", which is prose built
// from the path. Reduce the error to `(domain, code)` instead; ChalkKit's
// `DiagError` exists for exactly this.
//
// Alert copy is untouched: showing users the name of their own file is correct.
// Only interpolations that are explicitly `.public` are flagged.
function interpolations(line) {
  const found = [];
  for (let i = 0; i < line.length - 1; i++) {
    if (line[i] !== '\\' || line[i + 1] !== '(') continue;
    let depth = 0;
    for (let j = i + 1; j < line.length; j++) {
      if (line[j] === '(') depth++;
      else if (line[j] === ')' && --depth === 0) {
        found.push(line.slice(i + 2, j));
        i = j;
        break;
      }
    }
  }
  return found;
}

const glueDir = join(root, 'mac/ChalkAppKitGlue');
const logFiles = [...swiftFiles];
(function walkGlue(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walkGlue(full);
    else if (entry.endsWith('.swift')) logFiles.push(full);
  }
})(glueDir);

for (const file of logFiles) {
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((line, i) => {
    if (!line.includes('privacy: .public')) return;
    for (const segment of interpolations(line)) {
      if (!segment.includes('privacy: .public')) continue;
      for (const carrier of CARRIERS) {
        if (!segment.includes(carrier)) continue;
        problems.push(
          `${relative(root, file)}:${i + 1}: a log interpolation marked .public `
          + `reads ${carrier}, which carries user data:\n      ${line.trim()}`);
      }
    }
  });
}

if (problems.length > 0) {
  console.error('[check-diagnostics-purity] the diagnostics payload can carry user data:');
  for (const p of problems) console.error(`  - ${p}`);
  console.error('Diagnostics events must be enums and numbers only. See DiagnosticsRing.swift.');
  process.exit(1);
}
console.log(`[check-diagnostics-purity] ring ingress is text-free; ${logFiles.length} sources clean of public leaks.`);
