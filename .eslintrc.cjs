/**
 * Minimal ESLint config for the Chalk extension. Catches obvious
 * mistakes (unused variables, accidental any, equality bugs) without
 * imposing a style layer that would conflict with TypeScript's own
 * checking. The TS compiler is the source of truth for types; ESLint
 * adds the lint rules TS doesn't enforce.
 */
module.exports = {
  root: true,
  parser: '@typescript-eslint/parser',
  parserOptions: {
    ecmaVersion: 2022,
    sourceType: 'module',
  },
  plugins: ['@typescript-eslint'],
  extends: [
    'eslint:recommended',
    'plugin:@typescript-eslint/recommended',
  ],
  env: {
    node: true,
    browser: true,
    es2022: true,
  },
  ignorePatterns: ['dist/', 'out/', 'node_modules/', '*.vsix'],
  rules: {
    // Unused vars: allow underscore-prefixed ones (used as a convention
    // for parameters that exist for typing but aren't read in the body).
    '@typescript-eslint/no-unused-vars': [
      'warn',
      { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
    ],
    // CM6 frequently uses `any` in callback signatures; relax to warn.
    '@typescript-eslint/no-explicit-any': 'warn',
    // Style preferences kept off — TS + format-on-save handles them.
    '@typescript-eslint/no-empty-function': 'off',
  },
};
