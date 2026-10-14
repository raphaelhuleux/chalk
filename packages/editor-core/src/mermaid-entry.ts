/**
 * The mermaid renderer, built by each host as its own script (web/build.mjs,
 * vscode/esbuild.config.js) and loaded on the first ```mermaid fence by
 * scriptMermaidLoader. Kept out of the editor bundle: minified, mermaid is
 * several times the size of everything else.
 */
import mermaid from 'mermaid';
import { MERMAID_GLOBAL, type MermaidRenderer, type MermaidTheme } from './editor/mermaid-api';

let configured: string | null = null;
let seq = 0;
// One render at a time: `initialize` swaps mermaid's global config, so a theme
// change must not land under a render that is still in flight.
let queue: Promise<unknown> = Promise.resolve();

function configure(theme: MermaidTheme): void {
  const key = JSON.stringify(theme);
  if (key === configured) return;
  configured = key;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    // Without it a parse error also appends mermaid's error diagram to <body>.
    suppressErrorRendering: true,
    theme: theme.dark ? 'dark' : 'neutral',
    darkMode: theme.dark,
    fontFamily: theme.fontFamily,
  });
}

const renderer: MermaidRenderer = {
  render(source, theme) {
    const result = queue.then(async () => {
      configure(theme);
      return (await mermaid.render(`chalk-mermaid-${++seq}`, source)).svg;
    });
    queue = result.catch(() => undefined);
    return result;
  },
};

(globalThis as Record<string, unknown>)[MERMAID_GLOBAL] = renderer;
