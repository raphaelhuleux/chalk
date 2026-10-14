/** Hand-written declarations for rules.mjs. */
import type { MatrixCell, MatrixInstance } from './compose.mjs';

export interface Sel {
  anchor: number;
  head: number;
}
export interface HiddenExtent {
  from: number;
  to: number;
  block: boolean;
}
export type Topology =
  | { kind: 'row'; targetLine: number; ruleId: string }
  | { kind: 'stop'; targetLine: number; ruleId: string }
  | { kind: 'table'; pos: number; ruleId: string }
  | { kind: 'edge' };

export declare function lineOfPos(cell: MatrixCell, pos: number): number;
export declare function instanceRevealed(
  cell: MatrixCell,
  inst: MatrixInstance,
  sel: Sel,
  flags?: { override?: boolean },
): boolean;
export declare function predictHidden(
  cell: MatrixCell,
  sel: Sel,
  flags?: { override?: boolean },
): HiddenExtent[];
export declare function constructExtents(cell: MatrixCell): Array<[number, number]>;
export declare function isInsideHidden(
  cell: MatrixCell,
  sel: Sel,
  pos: number,
  flags?: { override?: boolean },
): boolean;
export declare function predictWidgets(
  cell: MatrixCell,
  sel: Sel,
  flags?: { override?: boolean },
): Array<{ pos: number; side: number; block: boolean }>;
export declare function predictAtomic(cell: MatrixCell, sel: Sel): Array<{ from: number; to: number }>;
export declare function predictHorizontal(
  cell: MatrixCell,
  head: number,
  dir: 1 | -1,
  sel?: Sel,
): number;
export declare function verticalTopology(
  cell: MatrixCell,
  head: number,
  dir: 1 | -1,
  sel?: Sel,
  opts?: { sameLineRow?: boolean },
): Topology;
export declare function stopLanding(cell: MatrixCell, head: number, targetLine: number): number;
export declare function applySnap(
  cell: MatrixCell,
  sel: Sel,
  pos: number,
  flags?: { override?: boolean },
): number;
export declare function clickTargets(
  cell: MatrixCell,
): Array<{ selector: string; nth: number; land: number; rule: string; construct: string }>;
export declare function ruleForRange(cell: MatrixCell, from: number, to: number): string;
