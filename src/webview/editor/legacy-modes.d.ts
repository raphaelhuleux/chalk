// @codemirror/legacy-modes ships a flat .cjs file per mode but no .d.ts
// files for its submodule paths. StreamLanguage.define wants a StreamParser;
// typing it as `any` keeps strict mode happy without having to fork the
// legacy-modes package. Narrow to `unknown` if we ever want tighter typing
// — the tradeoff is noisy casts at every call site.

declare module '@codemirror/legacy-modes/mode/stex' {
  import type { StreamParser } from '@codemirror/language';
  export const stex: StreamParser<unknown>;
  export const stexMath: StreamParser<unknown>;
}
