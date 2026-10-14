/**
 * How many automatic equation numbers a KaTeX render emits — one per
 * `.eqn-num` element (`equation`/`align`/`gather` rows without `\notag` or an
 * explicit `\tag`). Exact by construction for every environment form, which
 * makes it the oracle for the source-side count the editor actually uses
 * (`countSourceEquationNumbers`). The quoted match skips the assistive
 * `"mml-eqn-num"` duplicate.
 */
export function countEquationNumbers(html: string | null): number {
  if (!html) return 0;
  return (html.match(/"eqn-num"/g) ?? []).length;
}
