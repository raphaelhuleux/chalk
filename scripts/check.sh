#!/usr/bin/env bash
#
# One command that says whether Chalk is healthy.
#
#   ./scripts/check.sh              # everything
#   ./scripts/check.sh --fast       # skip the Xcode test suites and the benchmarks
#   ./scripts/check.sh --no-bench   # everything except the benchmarks
#   ./scripts/check.sh --list       # print the steps and exit
#
# Exit 0 only if every step passed.
#
# Failures are printed in a fixed, greppable shape so another agent can act on
# them without re-reading this script:
#
#   FAILURE <n>
#     step:     <step name>
#     file:     <path, or "-">
#     case:     <test or fixture name, or "-">
#     expected: <one line, or "-">
#     actual:   <one line, or "-">
#     log:      <path to the full output>
#
# Every step runs even after an earlier one fails, so one invocation reports
# the whole picture.
#
# Written for bash 3.2, the system shell on macOS: no associative arrays, no
# mapfile, no ${var^^}.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RESULTS="$ROOT/.harness/results"
rm -rf "$RESULTS"
mkdir -p "$RESULTS"

RUN_XCTEST=1
RUN_BENCH=1
LIST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --fast) RUN_XCTEST=0; RUN_BENCH=0 ;;
    --no-bench) RUN_BENCH=0 ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$LIST_ONLY" = "1" ]; then
  cat <<'STEPS'
build-web        esbuild bundle the editor ships
typecheck        tsc across editor-core, vscode, web
xcodegen         regenerate mac/Chalk.xcodeproj from mac/project.yml
build-mac        xcodebuild build-for-testing, warnings as errors
invariants-doc   docs/ui-invariants.md matches the Swift catalogue
engine-tests     vitest, the editor engine in jsdom
chalkkit-tests   swift test, the Foundation-only module
caret-fixtures   Tests/fixtures/caret, headless Chromium
browser-tests    Tests/browser/run.mjs, pointer and motion over real geometry
geometric-matrix Tests/matrix/run-geometric.mjs, the caret/reveal discovery matrix
snapshots        Tests/__Snapshots__, the 16-case layout matrix
pref-guard       no earlier run left a test preference in the Debug domain
ui-invariants    chrome geometry asserted across the 32-state matrix
mac-tests        the rest of ChalkTests
bench            scripts/bench.sh against thresholds.json
STEPS
  exit 0
fi

MAC='platform=macOS'
DD="$ROOT/mac/build/dd"          # gitignored; keeps xcodebuild incremental
WARN_FLAGS="SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES"

# --- step plumbing ----------------------------------------------------------
FAILED_STEPS=""
STEP_COUNT=0
PASS_COUNT=0

# run_step <name> <command...>
# Never aborts the script: the status is recorded and reporting happens at the end.
run_step() {
  name="$1"; shift
  STEP_COUNT=$((STEP_COUNT + 1))
  log="$RESULTS/$name.log"
  printf '  %-16s ' "$name"
  start=$(date +%s)
  if "$@" >"$log" 2>&1; then
    end=$(date +%s)
    printf 'ok      %ss\n' "$((end - start))"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    end=$(date +%s)
    printf 'FAILED  %ss\n' "$((end - start))"
    FAILED_STEPS="$FAILED_STEPS $name"
  fi
}

xcode_test() {
  # shellcheck disable=SC2086
  xcodebuild test \
    -project mac/Chalk.xcodeproj \
    -scheme Chalk \
    -destination "$MAC" \
    -derivedDataPath "$DD" \
    $WARN_FLAGS \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
}

xcode_build() {
  # shellcheck disable=SC2086
  xcodebuild build-for-testing \
    -project mac/Chalk.xcodeproj \
    -scheme Chalk \
    -destination "$MAC" \
    -derivedDataPath "$DD" \
    $WARN_FLAGS \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
}

echo "chalk check"
echo "  logs: ${RESULTS#$ROOT/}"
echo

# --- build ------------------------------------------------------------------
run_step build-web node web/build.mjs
run_step typecheck pnpm typecheck
# The Xcode project is generated and gitignored, so it must exist before any
# xcodebuild step. Cheap and idempotent.
run_step xcodegen sh -c 'cd mac && xcodegen generate'
# build-for-testing compiles the app and the ChalkTests bundle, so a test-only
# compile error (warnings as errors included) fails here even under --fast.
run_step build-mac xcode_build

# --- engine and headless logic ----------------------------------------------
# Cheap and test-run-free, so it runs even under --fast: the generated
# catalogue is the document people read INSTEAD of the Swift, so it drifting is
# a correctness bug of its own.
run_step invariants-doc node scripts/generate-ui-invariants.mjs --check
run_step engine-tests pnpm test
run_step chalkkit-tests pnpm test:swift
run_step caret-fixtures node Tests/runner/caret-fixtures.mjs --no-build
run_step browser-tests node Tests/browser/run.mjs --no-build
run_step geometric-matrix node Tests/matrix/run-geometric.mjs --no-build
run_step snapshots node Tests/runner/snapshots.mjs --no-build

# --- Xcode test suites ------------------------------------------------------
if [ "$RUN_XCTEST" = "1" ]; then
  # pref-guard runs BEFORE the matrix suite: a killed run can leave a test
  # preference in the Debug domain (com.huleux.chalk.debug), and the guard
  # should name it before more suites fail because of it.
  run_step pref-guard xcode_test -only-testing:ChalkTests/PreferencePollutionGuardTests
  run_step ui-invariants xcode_test -only-testing:ChalkTests/ChromeInvariantMatrixTests
  # The whole bundle minus the two classes the steps above already ran:
  # running them again doubles the matrix's cost and reports any failure of
  # theirs twice.
  run_step mac-tests xcode_test \
    -skip-testing:ChalkTests/PreferencePollutionGuardTests \
    -skip-testing:ChalkTests/ChromeInvariantMatrixTests
else
  echo "  (skipping pref-guard, ui-invariants, mac-tests: --fast)"
fi

if [ "$RUN_BENCH" = "1" ]; then
  # build-web above already built the bundle bench.sh would build.
  run_step bench "$ROOT/scripts/bench.sh" --no-build
else
  echo "  (skipping bench)"
fi

# --- failure extraction -----------------------------------------------------
#
# Each extractor turns one step's log into zero or more records on stdout, four
# lines per record: file, case, expected, actual. "-" for anything absent.

emit() {
  printf '%s\n%s\n%s\n%s\n' "${1:--}" "${2:--}" "${3:--}" "${4:--}"
}

extract_xcode() {
  # Xcode prints: /path/File.swift:42: error: -[Suite testCase] : XCTAssertEqual failed: ("a") is not equal to ("b")
  grep -E '^.+:[0-9]+: error: -\[' "$1" 2>/dev/null | while IFS= read -r line; do
    file="$(printf '%s' "$line" | sed -E 's/^(.+:[0-9]+): error:.*$/\1/')"
    case_name="$(printf '%s' "$line" | sed -E 's/^.*error: -\[([^]]+)\].*$/\1/')"
    msg="$(printf '%s' "$line" | sed -E 's/^.*error: -\[[^]]+\] *: *//')"
    exp="$(printf '%s' "$msg" | sed -nE 's/.*\("([^"]*)"\) is not equal to \("([^"]*)"\).*/\1/p')"
    act="$(printf '%s' "$msg" | sed -nE 's/.*\("([^"]*)"\) is not equal to \("([^"]*)"\).*/\2/p')"
    if [ -n "$exp" ] || [ -n "$act" ]; then
      emit "$file" "$case_name" "$exp" "$act"
    else
      emit "$file" "$case_name" "-" "$msg"
    fi
  done
  # Compiler errors, including the warnings-as-errors ones.
  grep -E '^.+:[0-9]+:[0-9]+: error: ' "$1" 2>/dev/null | head -20 | while IFS= read -r line; do
    file="$(printf '%s' "$line" | sed -E 's/^(.+:[0-9]+):[0-9]+: error:.*$/\1/')"
    msg="$(printf '%s' "$line" | sed -E 's/^.+:[0-9]+:[0-9]+: error: //')"
    emit "$file" "compile" "-" "$msg"
  done
}

extract_caret() {
  # The fixture runner prints: FAIL <path>, then "exp N | ..." / "got N | ..."
  awk '
    /^FAIL / { file=$2; exp=""; act=""; next }
    /^  exp [0-9]+ \| / && file != "" && exp == "" { sub(/^  exp [0-9]+ \| /, ""); exp=$0; next }
    /^  got [0-9]+ \| / && file != "" && act == "" { sub(/^  got [0-9]+ \| /, ""); act=$0;
      print file; print "caret fixture"; print exp; print act; file=""; next }
  ' "$1" 2>/dev/null
}

extract_vitest() {
  grep -E '^ *(FAIL|×) ' "$1" 2>/dev/null | head -20 | while IFS= read -r line; do
    cleaned="$(printf '%s' "$line" | sed -E 's/^ *(FAIL|×) //')"
    file="$(printf '%s' "$cleaned" | sed -E 's/^([^ ]+).*$/\1/')"
    emit "$file" "$cleaned" "-" "-"
  done
}

extract_swift() {
  grep -E '^.+:[0-9]+: error: ' "$1" 2>/dev/null | head -20 | while IFS= read -r line; do
    file="$(printf '%s' "$line" | sed -E 's/^(.+:[0-9]+): error:.*$/\1/')"
    msg="$(printf '%s' "$line" | sed -E 's/^.+:[0-9]+: error: //')"
    case_name="$(printf '%s' "$msg" | sed -nE 's/^.*\.([A-Za-z0-9_]+) : .*$/\1/p')"
    emit "$file" "$case_name" "-" "$msg"
  done
}

extract_browser() {
  # The scenario runner prints each scenario's name unindented, then one line
  # per check: "  FAIL <check>  (<detail>)", or "  XPASS <check>  (...)" for a
  # KNOWN_FAILURES.txt entry that passed. "[<lane>] ..." is the summary.
  awk '
    /^\[/ { next }
    /^[^ ]/ { scenario=$0; next }
    /^  FAIL / { check=substr($0, 8); detail="-"; i=index(check, "  (");
      if (i > 0) { detail=substr(check, i + 3); sub(/\)$/, "", detail); check=substr(check, 1, i - 1) }
      print "Tests/browser/run.mjs"; print scenario " :: " check; print "-"; print detail; next }
    /^  XPASS / { check=substr($0, 9); i=index(check, "  (");
      if (i > 0) check=substr(check, 1, i - 1);
      print "Tests/browser/KNOWN_FAILURES.txt"; print scenario " :: " check;
      print "listed as known-failing"; print "passed; remove the entry"; next }
  ' "$1" 2>/dev/null
}

extract_geometric() {
  # The matrix runner prints: [<lane>] FAIL <cellId> <ruleId>, then indented
  # detail lines carrying the exp/got text.
  awk '
    /^\[[a-z-]+\] FAIL / { cell=$3; rule=$4; want=1; next }
    want && /^\[[a-z-]+\]   / { sub(/^\[[a-z-]+\]   /, "");
      print "Tests/matrix/run-geometric.mjs"; print cell " " rule; print "-"; print $0; want=0; next }
    { want=0 }
  ' "$1" 2>/dev/null
}

extract_snapshots() {
  # The runner prints: FAIL <name>, then indented expected/actual paths.
  awk '
    /^FAIL / { name=$2; exp=""; next }
    /^  expected: / && name != "" { sub(/^  expected: /, ""); exp=$0; next }
    /^  actual:   / && name != "" { sub(/^  actual:   /, "");
      print exp; print name; print "the recorded baseline"; print $0; name=""; next }
  ' "$1" 2>/dev/null
}

extract_bench() {
  # bench.sh prints: OVER <metric> median=<x> threshold=<y>
  grep -E '^OVER ' "$1" 2>/dev/null | while IFS= read -r line; do
    metric="$(printf '%s' "$line" | awk '{print $2}')"
    median="$(printf '%s' "$line" | sed -nE 's/.*median=([^ ]+).*/\1/p')"
    thresh="$(printf '%s' "$line" | sed -nE 's/.*threshold=([^ ]+).*/\1/p')"
    emit "thresholds.json" "$metric" "<= $thresh" "$median"
  done
}

extract_for_step() {
  case "$1" in
    caret-fixtures) extract_caret "$2" ;;
    browser-tests) extract_browser "$2" ;;
    engine-tests) extract_vitest "$2" ;;
    chalkkit-tests) extract_swift "$2" ;;
    mac-tests|pref-guard|ui-invariants|build-mac) extract_xcode "$2" ;;
    geometric-matrix) extract_geometric "$2" ;;
    snapshots) extract_snapshots "$2" ;;
    bench) extract_bench "$2" ;;
    *) : ;;
  esac
}

# --- report -----------------------------------------------------------------
echo
if [ -z "$FAILED_STEPS" ]; then
  echo "PASS  $PASS_COUNT/$STEP_COUNT steps"
  exit 0
fi

n=0
for step in $FAILED_STEPS; do
  log="$RESULTS/$step.log"
  records="$(extract_for_step "$step" "$log" || true)"
  if [ -z "$records" ]; then
    n=$((n + 1))
    echo "FAILURE $n"
    echo "  step:     $step"
    echo "  file:     -"
    echo "  case:     -"
    echo "  expected: -"
    echo "  actual:   step failed without a parsable assertion; read the log"
    echo "  log:      ${log#$ROOT/}"
    echo
    continue
  fi
  # Four lines per record.
  printf '%s\n' "$records" | while IFS= read -r file; do
    IFS= read -r case_name || break
    IFS= read -r expected || break
    IFS= read -r actual || break
    n=$((n + 1))
    echo "FAILURE $n"
    echo "  step:     $step"
    echo "  file:     ${file:--}"
    echo "  case:     ${case_name:--}"
    echo "  expected: ${expected:--}"
    echo "  actual:   ${actual:--}"
    echo "  log:      ${log#$ROOT/}"
    echo
  done
done

echo "FAIL  $PASS_COUNT/$STEP_COUNT steps passed; failed:$FAILED_STEPS"
exit 1
