#!/usr/bin/env bash
#
# Performance gate for the editor engine.
#
#   ./scripts/bench.sh              # 5 runs, median vs thresholds.json
#   ./scripts/bench.sh --record     # 5 runs, WRITE thresholds.json from the medians
#   ./scripts/bench.sh --runs 3     # fewer runs (noisier; for local iteration only)
#   ./scripts/bench.sh --no-build   # reuse the existing web/dist bundle
#
# Each metric is measured `--runs` times and reduced to its median, because one
# run of any of them is noise. A metric fails when its median exceeds the
# recorded threshold by more than 10 percent.
#
# Failures print as, one per line, which is what scripts/check.sh parses:
#
#   OVER <metric> median=<value> threshold=<value> limit=<threshold*1.1>
#
# Exit 0 only if every metric is within its limit.
#
# Written for bash 3.2, the system shell on macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

THRESHOLDS="$ROOT/thresholds.json"
RUNS=5
RECORD=0
BUILD_FLAG=""
TOLERANCE=1.10

while [ $# -gt 0 ]; do
  case "$1" in
    --record) RECORD=1 ;;
    --no-build) BUILD_FLAG="--no-build" ;;
    --runs) shift; RUNS="${1:?--runs needs a number}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$RECORD" = "0" ] && [ ! -f "$THRESHOLDS" ]; then
  echo "missing $THRESHOLDS — record a baseline first: ./scripts/bench.sh --record" >&2
  exit 2
fi

# The bundle is built once here rather than per run, so the five runs measure
# the same artifact and do not pay the esbuild cost five times.
if [ -z "$BUILD_FLAG" ]; then
  node web/build.mjs >/dev/null
fi

RAW="$(mktemp -t chalkbench)"
trap 'rm -f "$RAW"' EXIT

echo "bench: $RUNS runs"
run=1
while [ "$run" -le "$RUNS" ]; do
  printf '  run %s/%s ... ' "$run" "$RUNS"
  if ! node "$ROOT/Tests/runner/bench.mjs" --no-build >>"$RAW" 2>/tmp/chalkbench.err; then
    echo "FAILED"
    echo "benchmark run $run did not complete:" >&2
    tail -20 /tmp/chalkbench.err >&2
    exit 1
  fi
  tail -1 "$RAW"
  run=$((run + 1))
done

# Median, comparison and (optionally) recording all happen in one node pass:
# doing float maths in bash 3.2 is how thresholds quietly become wrong.
node - "$RAW" "$THRESHOLDS" "$RECORD" "$TOLERANCE" <<'NODE_EOF'
const fs = require('fs');
const [rawPath, thresholdsPath, record, tolerance] = process.argv.slice(2);

const runs = fs.readFileSync(rawPath, 'utf8')
  .split('\n')
  .filter((l) => l.trim().startsWith('{'))
  .map((l) => JSON.parse(l));

if (!runs.length) {
  console.error('no benchmark output was produced');
  process.exit(1);
}

const median = (xs) => {
  const s = xs.slice().sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
};

const metrics = Object.keys(runs[0]);
const medians = {};
for (const m of metrics) {
  medians[m] = Math.round(median(runs.map((r) => r[m])) * 100) / 100;
}

console.log('\nmedians over ' + runs.length + ' runs:');
for (const m of metrics) console.log('  ' + m.padEnd(22) + medians[m]);

if (record === '1') {
  // Preserve a hand-tuned noise floor across re-recordings: it describes the
  // measurement, not the machine's speed, so a new baseline should not silently
  // drop it.
  let existingFloor = null;
  try { existingFloor = JSON.parse(fs.readFileSync(thresholdsPath, 'utf8'))._noise_floor || null; } catch (e) { /* first run */ }

  const payload = {
    _comment:
      'Recorded by scripts/bench.sh --record. Medians from this machine; a metric ' +
      'fails when its median exceeds the value here by more than 10 percent. ' +
      'These are headless-Chromium numbers for the web engine, not whole-app numbers. ' +
      'Re-record only on a deliberate, reviewed performance decision.',
    _recorded: { runs: runs.length, node: process.version, platform: process.platform, arch: process.arch },
    _noise_floor: existingFloor || {
      key_to_model_p95_ms: 3,
      render_200_math_ms: 0,
      idle_cpu_percent: 0.15,
      peak_heap_mb: 1,
    },
    ...medians,
  };
  fs.writeFileSync(thresholdsPath, JSON.stringify(payload, null, 2) + '\n');
  console.log('\nwrote ' + thresholdsPath);
  process.exit(0);
}

const thresholds = JSON.parse(fs.readFileSync(thresholdsPath, 'utf8'));

// A 10 percent band is meaningless on a metric whose absolute value is near
// zero: idle CPU sits around 0.2 percent, so 10 percent of it is 0.02
// percentage points, well inside measurement noise, and the gate would fail on
// nothing. A metric must therefore exceed BOTH the relative band and an
// absolute floor before it counts as a regression. The floors are calibrated
// to observed run-to-run spread, not chosen to make anything pass.
const NOISE_FLOOR = thresholds._noise_floor || {};

let over = 0;
let missing = 0;
console.log('');
for (const m of metrics) {
  if (typeof thresholds[m] !== 'number') {
    console.log('MISSING ' + m + ' has no threshold; re-record with --record');
    missing++;
    continue;
  }
  const floor = typeof NOISE_FLOOR[m] === 'number' ? NOISE_FLOOR[m] : 0;
  const limit = Math.max(thresholds[m] * Number(tolerance), thresholds[m] + floor);
  if (medians[m] > limit) {
    console.log(
      'OVER ' + m + ' median=' + medians[m] + ' threshold=' + thresholds[m] +
        ' limit=' + (Math.round(limit * 100) / 100),
    );
    over++;
  } else {
    const pct = Math.round(((medians[m] - thresholds[m]) / thresholds[m]) * 1000) / 10;
    console.log('ok   ' + m.padEnd(22) + medians[m] + '  (' + (pct >= 0 ? '+' : '') + pct + '% vs threshold)');
  }
}

if (over || missing) {
  console.log('\nFAIL ' + over + ' metric(s) over budget, ' + missing + ' without a threshold');
  process.exit(1);
}
console.log('\nPASS all metrics within budget');
NODE_EOF
