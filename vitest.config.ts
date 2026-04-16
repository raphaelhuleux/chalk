import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  resolve: {
    alias: {
      vscode: path.resolve(__dirname, 'test/stubs/vscode.ts'),
    },
  },
  test: {
    environment: 'jsdom',
    include: ['test/**/*.test.ts'],
    passWithNoTests: true,
  },
});
