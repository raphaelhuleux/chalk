import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as fs from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';

/**
 * Which theme the readers resolve. VS Code shows `workbench.colorTheme` only
 * when it is not following the OS; the API names just the active theme's kind.
 */
const fake = vi.hoisted(() => {
  const settings: Record<string, unknown> = {};
  const state = {
    settings,
    kind: 2,
    extensionPath: '/themes',
    themes: [] as { label: string; uiTheme: string; path: string }[],
  };
  const api = {
    ColorThemeKind: { Light: 1, Dark: 2, HighContrast: 3, HighContrastLight: 4 },
    workspace: {
      getConfiguration: (section: string) => ({
        get: (key: string) => state.settings[`${section}.${key}`],
      }),
    },
    window: {
      get activeColorTheme() {
        return { kind: state.kind };
      },
    },
    extensions: {
      get all() {
        return [
          {
            extensionPath: state.extensionPath,
            packageJSON: { contributes: { themes: state.themes } },
          },
        ];
      },
    },
  };
  return { api, state };
});

vi.mock('vscode', () => fake.api);

import {
  activeThemeLabel,
  loadActiveTheme,
  readThemeColors,
} from '../../src/extension/theme-reader';
import { getMarkdownHeadingColors } from '../../src/extension/markdown-heading-colors';

const Light = 1;
const Dark = 2;
const HighContrast = 3;

function configure(settings: Record<string, unknown>, kind: number): void {
  for (const key of Object.keys(fake.state.settings)) delete fake.state.settings[key];
  Object.assign(fake.state.settings, {
    // VS Code's defaults.
    'window.autoDetectColorScheme': false,
    'window.autoDetectHighContrast': true,
    ...settings,
  });
  fake.state.kind = kind;
}

beforeEach(() => {
  fake.state.extensionPath = '/themes';
  fake.state.themes = [
    { label: 'Solarized Light', uiTheme: 'vs', path: 'sl.json' },
    { label: 'Monokai', uiTheme: 'vs-dark', path: 'mk.json' },
    { label: 'Tokyo Night', uiTheme: 'vs-dark', path: 'tn.json' },
    { label: 'Default High Contrast', uiTheme: 'hc-black', path: 'hc.json' },
    { label: 'GitHub Dark High Contrast', uiTheme: 'hc-black', path: 'ghhc.json' },
  ];
});

describe('activeThemeLabel', () => {
  it('reads workbench.colorTheme when VS Code does not follow the OS', () => {
    configure({ 'workbench.colorTheme': 'Monokai' }, Dark);
    expect(activeThemeLabel()).toBe('Monokai');
  });

  it('reads the preferred theme for the kind VS Code shows when auto-detecting', () => {
    const settings = {
      'window.autoDetectColorScheme': true,
      // Stale: picking a theme while auto-detecting writes the preferred one.
      'workbench.colorTheme': 'Monokai',
      'workbench.preferredDarkColorTheme': 'Tokyo Night',
      'workbench.preferredLightColorTheme': 'Solarized Light',
    };
    configure(settings, Light);
    expect(activeThemeLabel()).toBe('Solarized Light');
    configure(settings, Dark);
    expect(activeThemeLabel()).toBe('Tokyo Night');
  });

  it('falls back to colorTheme when the preferred setting is empty', () => {
    configure({ 'window.autoDetectColorScheme': true, 'workbench.colorTheme': 'Monokai' }, Dark);
    expect(activeThemeLabel()).toBe('Monokai');
  });

  it('reads the preferred high-contrast theme for an OS in high-contrast mode', () => {
    configure(
      {
        'workbench.colorTheme': 'Monokai',
        'workbench.preferredHighContrastColorTheme': 'GitHub Dark High Contrast',
      },
      HighContrast,
    );
    expect(activeThemeLabel()).toBe('GitHub Dark High Contrast');
  });

  it('keeps a high-contrast colorTheme the user picked', () => {
    configure(
      {
        'workbench.colorTheme': 'GitHub Dark High Contrast',
        'workbench.preferredHighContrastColorTheme': 'Default High Contrast',
      },
      HighContrast,
    );
    expect(activeThemeLabel()).toBe('GitHub Dark High Contrast');
  });

  it('ignores the OS high-contrast mode when its detection is off', () => {
    configure(
      {
        'window.autoDetectHighContrast': false,
        'workbench.colorTheme': 'Monokai',
        'workbench.preferredHighContrastColorTheme': 'Default High Contrast',
      },
      HighContrast,
    );
    expect(activeThemeLabel()).toBe('Monokai');
  });
});

describe('theme readers follow the active theme', () => {
  it('read the preferred theme\'s file, not the stale colorTheme', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'chalk-theme-'));
    const theme = (color: string) =>
      JSON.stringify({
        tokenColors: [
          { scope: 'markup.heading.1.markdown', settings: { foreground: color } },
          { scope: 'keyword', settings: { foreground: color } },
        ],
      });
    await fs.writeFile(path.join(dir, 'stale.json'), theme('#222222'));
    await fs.writeFile(path.join(dir, 'shown.json'), theme('#111111'));
    fake.state.extensionPath = dir;
    fake.state.themes = [
      { label: 'Stale', uiTheme: 'vs-dark', path: 'stale.json' },
      { label: 'Shown', uiTheme: 'vs-dark', path: 'shown.json' },
    ];
    configure(
      {
        'window.autoDetectColorScheme': true,
        'workbench.colorTheme': 'Stale',
        'workbench.preferredDarkColorTheme': 'Shown',
      },
      Dark,
    );

    expect(await getMarkdownHeadingColors()).toEqual({ 1: '#111111' });
    const colors = await readThemeColors({
      keyword: ['keyword'],
      tagName: [],
      comment: [],
      number: [],
      atom: [],
      bracket: [],
      specialVariable: [],
      invalid: [],
    });
    expect(colors?.keyword).toBe('#111111');

    await fs.rm(dir, { recursive: true });
  });
});

describe('loadActiveTheme', () => {
  it('reads a theme once for every reader, and again after a switch', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'chalk-theme-'));
    const theme = (color: string) =>
      JSON.stringify({
        tokenColors: [{ scope: 'markup.heading.1.markdown', settings: { foreground: color } }],
      });
    await fs.writeFile(path.join(dir, 'a.json'), theme('#aaaaaa'));
    await fs.writeFile(path.join(dir, 'b.json'), theme('#bbbbbb'));
    fake.state.extensionPath = dir;
    fake.state.themes = [
      { label: 'A', uiTheme: 'vs-dark', path: 'a.json' },
      { label: 'B', uiTheme: 'vs-dark', path: 'b.json' },
    ];
    configure({ 'workbench.colorTheme': 'A' }, Dark);
    expect(await getMarkdownHeadingColors()).toEqual({ 1: '#aaaaaa' });

    // The file changes on disk; the readers keep the parse they already have.
    await fs.writeFile(path.join(dir, 'a.json'), theme('#a0a0a0'));
    expect(await getMarkdownHeadingColors()).toEqual({ 1: '#aaaaaa' });
    expect((await loadActiveTheme()).tokens).toHaveLength(1);

    // A theme switch misses the cache, and switching back reloads.
    configure({ 'workbench.colorTheme': 'B' }, Dark);
    expect(await getMarkdownHeadingColors()).toEqual({ 1: '#bbbbbb' });
    configure({ 'workbench.colorTheme': 'A' }, Dark);
    expect(await getMarkdownHeadingColors()).toEqual({ 1: '#a0a0a0' });

    await fs.rm(dir, { recursive: true });
  });

  it('does not keep an empty read', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'chalk-theme-'));
    fake.state.extensionPath = dir;
    fake.state.themes = [{ label: 'Late', uiTheme: 'vs-dark', path: 'late.json' }];
    configure({ 'workbench.colorTheme': 'Late' }, Dark);
    expect(await getMarkdownHeadingColors()).toEqual({});

    await fs.writeFile(
      path.join(dir, 'late.json'),
      JSON.stringify({
        tokenColors: [{ scope: 'markup.heading', settings: { foreground: '#cccccc' } }],
      }),
    );
    expect((await getMarkdownHeadingColors())[1]).toBe('#cccccc');

    await fs.rm(dir, { recursive: true });
  });
});
