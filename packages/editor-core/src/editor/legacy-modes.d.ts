// Ambient types for the legacy-modes submodules we import, as the
// `StreamParser` that StreamLanguage.define wants.

declare module '@codemirror/legacy-modes/mode/stex' {
  import type { StreamParser } from '@codemirror/language';
  export const stex: StreamParser<unknown>;
}

declare module '@codemirror/legacy-modes/mode/python' {
  import type { StreamParser } from '@codemirror/language';
  export const python: StreamParser<unknown>;
}

declare module '@codemirror/legacy-modes/mode/r' {
  import type { StreamParser } from '@codemirror/language';
  export const r: StreamParser<unknown>;
}

declare module '@codemirror/legacy-modes/mode/julia' {
  import type { StreamParser } from '@codemirror/language';
  export const julia: StreamParser<unknown>;
}
