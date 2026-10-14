import { readFileSync } from 'fs';
import path from 'path';
import { describe, expect, it } from 'vitest';

/** The contributed `chalk.viewMode` setting must offer exactly editor-core's
 *  three wire values, defaulting to preview. */
const pkg = JSON.parse(
  readFileSync(path.resolve(__dirname, '../../package.json'), 'utf8'),
) as {
  contributes: {
    configuration: { properties: Record<string, { enum?: string[]; default?: unknown }> };
  };
};

describe('chalk.viewMode setting', () => {
  it('offers preview, mixed and source, defaulting to preview', () => {
    const prop = pkg.contributes.configuration.properties['chalk.viewMode'];
    expect(prop).toBeDefined();
    expect(prop.enum).toEqual(['preview', 'mixed', 'source']);
    expect(prop.default).toBe('preview');
  });
});
