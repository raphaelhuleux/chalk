import { readFileSync } from 'fs';
import path from 'path';
import { describe, expect, it } from 'vitest';

/**
 * Locks the contributed keybindings against editor-core's own keymap.
 *
 * A VS Code webview does NOT consume the keys it handles. The preload's
 * `handleInnerKeydown` (workbench/contrib/webview/browser/pre/index.html)
 * forwards every keydown to the workbench as `did-keydown` without ever
 * looking at `defaultPrevented`, so a chord CodeMirror runs ALSO reaches the
 * keybinding service. Contribute a chord editor-core already owns and both
 * fire on one press — which is how `cmd+shift+;` came to toggle Chalk's
 * source mode *and* pop "Reopen Editor With…" on a US layout (the two are
 * separate physical keys on AZERTY, which is why it went unnoticed).
 *
 * The rule this file enforces: a contributed keybinding may only use a chord
 * from OWNED_CHORDS if its `when` clause proves no Chalk editor is focused.
 *
 * The other direction has the same cause: a chord editor-core owns that the
 * WORKBENCH also binds fires both. Undo is the case that matters: the
 * workbench's `undo` reaches the custom editor's TextDocument (its
 * custom-editor implementation checks only which editor is active, not focus),
 * so one Cmd+Z undid twice. Those chords are claimed back with a binding to
 * the no-op CLAIM_COMMAND, scoped to a Chalk editor with focus in the editor
 * area.
 */

interface Keybinding {
  command: string;
  key: string;
  mac?: string;
  when?: string;
}

const pkg = JSON.parse(
  readFileSync(path.resolve(__dirname, '../../package.json'), 'utf8'),
) as { contributes: { keybindings: Keybinding[] } };

const keybindings = pkg.contributes.keybindings;

/**
 * Chords editor-core binds inside the webview, in VS Code spelling.
 * Sourced from packages/editor-core/src/editor/setup.ts and the per-language
 * keymaps it composes; CM6's `Mod-` is `cmd` on macOS, `ctrl` elsewhere, and
 * `Mod-:` reaches VS Code as `shift+;` on a US layout.
 */
const OWNED_CHORDS: ReadonlyArray<{ chord: string; owner: string }> = [
  { chord: 'shift+;', owner: 'Mod-: — source-mode toggle (setup.ts)' },
  { chord: 'f', owner: 'Mod-f — Chalk find panel (setup.ts)' },
  { chord: 'b', owner: 'Mod-b — bold (format-shortcuts.ts)' },
  { chord: 'i', owner: 'Mod-i — italic (format-shortcuts.ts)' },
  { chord: 'p', owner: 'Mod-p — swallowed for the native outline (setup.ts)' },
  { chord: 'z', owner: 'Mod-z — undo (historyKeymap, setup.ts)' },
  { chord: 'shift+z', owner: 'Mod-Shift-z / Ctrl-Shift-z — redo, macOS / Linux (historyKeymap)' },
  { chord: 'y', owner: 'Mod-y — redo, Windows / Linux (historyKeymap)' },
];

/** The no-op command that claims a chord back from the workbench. */
const CLAIM_COMMAND = 'chalk.editorHandledKey';

/**
 * Workbench default bindings of `undo` / `redo` that CM6's historyKeymap also
 * handles, per platform, in VS Code spelling.
 */
const WORKBENCH_UNDO_REDO = {
  mac: ['cmd+z', 'cmd+shift+z'],
  other: ['ctrl+z', 'ctrl+y', 'ctrl+shift+z'],
};

const VIEW_TYPES = ['chalk.texEditor', 'chalk.markdownEditor'];

/** The suffix after the platform modifier, e.g. `cmd+shift+;` → `shift+;`. */
function chordBody(key: string, modifier: string): string | null {
  return key.startsWith(`${modifier}+`) ? key.slice(modifier.length + 1) : null;
}

/** Does `when` rule out every Chalk custom editor being the active one? */
function excludesChalkEditors(when: string | undefined): boolean {
  if (!when) return false;
  return VIEW_TYPES.every((v) => when.includes(`activeCustomEditorId != ${v}`));
}

/**
 * Does `when` hold only while a Chalk editor is active AND focus is in the
 * editor area? The focus half matters: `activeCustomEditorId` stays set while
 * focus is in the Explorer, the terminal or the SCM input, whose own Cmd+Z
 * must keep working.
 */
function requiresFocusedChalkEditor(when: string | undefined): boolean {
  if (!when) return false;
  return (
    VIEW_TYPES.every((v) => when.includes(`activeCustomEditorId == ${v}`)) &&
    /\)\s*&&\s*editorAreaFocus$/.test(when)
  );
}

describe('contributed keybindings', () => {
  it('never re-uses a chord editor-core owns while a Chalk editor is focused', () => {
    const collisions: string[] = [];
    for (const binding of keybindings) {
      if (excludesChalkEditors(binding.when)) continue;
      // Claims exist to take an owned chord back; checked below.
      if (binding.command === CLAIM_COMMAND) continue;
      for (const [key, modifier] of [
        [binding.mac, 'cmd'],
        [binding.key, 'ctrl'],
      ] as const) {
        if (!key) continue;
        const body = chordBody(key, modifier);
        const owned = OWNED_CHORDS.find((o) => o.chord === body);
        if (owned) {
          collisions.push(`${binding.command} on "${key}" collides with ${owned.owner}`);
        }
      }
    }
    expect(collisions).toEqual([]);
  });

  it('claims undo and redo from the workbench while a Chalk editor has focus', () => {
    const claims = keybindings.filter(
      (b) => b.command === CLAIM_COMMAND && requiresFocusedChalkEditor(b.when),
    );
    const macKeys = new Set(claims.map((b) => b.mac ?? b.key));
    const otherKeys = new Set(claims.map((b) => b.key));
    for (const key of WORKBENCH_UNDO_REDO.mac) expect(macKeys).toContain(key);
    for (const key of WORKBENCH_UNDO_REDO.other) expect(otherKeys).toContain(key);
  });

  it('claims only chords editor-core owns, and only while a Chalk editor has focus', () => {
    for (const binding of keybindings.filter((b) => b.command === CLAIM_COMMAND)) {
      expect(requiresFocusedChalkEditor(binding.when)).toBe(true);
      for (const [key, modifier] of [
        [binding.mac ?? binding.key, 'cmd'],
        [binding.key, 'ctrl'],
      ] as const) {
        const body = chordBody(key, modifier);
        expect(OWNED_CHORDS.map((o) => o.chord)).toContain(body);
      }
    }
  });

  it('registers the claim command and hides it from the Command Palette', () => {
    const index = readFileSync(
      path.resolve(__dirname, '../../src/extension/index.ts'),
      'utf8',
    );
    expect(index).toContain(`registerCommand('${CLAIM_COMMAND}'`);
    const palette = (
      pkg.contributes as { menus?: { commandPalette?: { command: string; when?: string }[] } }
    ).menus?.commandPalette;
    expect(palette).toContainEqual({ command: CLAIM_COMMAND, when: 'false' });
  });

  it('keeps both reopen directions reachable', () => {
    const reopen = keybindings.filter(
      (b) => b.command === 'workbench.action.reopenWithEditor',
    );
    // One binding for "I am in a text editor, open this in Chalk"…
    expect(reopen.some((b) => excludesChalkEditors(b.when))).toBe(true);
    // …and one for the way back out, which must be scoped to Chalk editors so
    // it cannot fire from an unrelated editor.
    const fromChalk = reopen.filter((b) =>
      VIEW_TYPES.every((v) => b.when?.includes(`activeCustomEditorId == ${v}`)),
    );
    expect(fromChalk).toHaveLength(1);
    expect(fromChalk[0].mac).toBe('cmd+alt+;');
  });

  it('binds every contributed keybinding to a real command', () => {
    const declared = new Set(
      (pkg.contributes as { commands?: { command: string }[] }).commands?.map(
        (c) => c.command,
      ) ?? [],
    );
    for (const binding of keybindings) {
      // Built-in workbench commands are not declared by this extension.
      if (binding.command.startsWith('workbench.')) continue;
      expect(declared).toContain(binding.command);
    }
  });
});
