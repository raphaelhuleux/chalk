import { describe, it, expect, beforeEach } from 'vitest';
import { createEditor } from '../src/editor/setup';
import { parsed } from './helpers/force-parse';

// A `---` line is valid CommonMark HorizontalRule syntax, but Chalk deliberately
// leaves it as raw markdown: it must never collapse into a blank line or render
// as an <hr>. See the HorizontalRule branch in md-live-preview.ts.
describe('horizontal rule stays raw in md editor', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('does not replace `---` with an <hr> widget', () => {
    const parent = document.createElement('div');
    document.body.appendChild(parent);
    const view = parsed(createEditor(
      parent,
      'above\n\n---\n\nbelow',
      { onContentChange: () => {} },
      'md',
    ));
    expect(view.dom.querySelector('hr')).toBeNull();
    // The literal characters remain in the rendered content.
    expect(view.dom.querySelector('.cm-content')!.textContent).toContain('---');
    view.destroy();
    parent.remove();
  });
});
