import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      // The extension-host tests import modules that `import 'vscode'`; the
      // real API only exists at runtime inside VS Code, so stub it.
      vscode: path.resolve(__dirname, 'test/stubs/vscode.ts'),
    },
  },
  test: {
    environment: 'jsdom',
    include: ['test/**/*.test.ts'],
    passWithNoTests: true,
  },
});
