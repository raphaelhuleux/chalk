/** Hand-written declarations for compose.mjs (the vitest structural lane
 *  imports the matrix .mjs files; tsc resolves these siblings for types). */

export interface MatrixInstance {
  kind:
    | 'inline-math'
    | 'display-math'
    | 'display-unclosed'
    | 'command'
    | 'pill'
    | 'href'
    | 'whole-replace'
    | 'marker-pair'
    | 'heading-attr'
    | 'callout'
    | 'list'
    | 'frame'
    | 'table'
    | 'none';
  rule: string;
  construct: string;
  from?: number;
  to?: number;
  cmdFrom?: number;
  argFrom?: number;
  argTo?: number;
  textFrom?: number;
  textTo?: number;
  nodeFrom?: number;
  nodeTo?: number;
  attrFrom?: number;
  hides?: Array<{ from: number; to: number }>;
  openLine?: number;
  closeLine?: number;
  openHasArgs?: boolean;
  items?: Array<{ line: number; from: number; to: number }>;
  fromLine?: number;
  toLine?: number;
  clickTarget?: { selector: string; land: number | string } | null;
}

export interface MatrixCell {
  id: string;
  language: 'tex' | 'md';
  construct: string;
  context: string;
  doc: string;
  width: number;
  viewport: 'desktop' | 'narrow';
  instances: MatrixInstance[];
}

export declare const VIEWPORTS: Record<'desktop' | 'narrow', { width: number; height: number }>;
export declare function composeCells(): MatrixCell[];
export declare function structuralCells(): MatrixCell[];
