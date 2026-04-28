#!/usr/bin/env bash
# smoketest.sh — end-to-end validation of the quorum-sync benchmark pipeline.
#
# Runs a condensed pass of the full scenario matrix (20 s measure, 10 s warmup,
# concurrency 16) against a local cockroach binary to verify that all scripts,
# cluster setup, settings application, metric capture, and analysis work
# end-to-end. Takes ~3–4 minutes.
#
# Usage:
#   ./smoketest.sh [path-to-cockroach-binary]
#
# If no binary is given, falls back to ./cockroach then cockroach in $PATH.
# The cockroach binary must include both the server and the workload subcommand
# (i.e. a full dev build, not just a short build without UI doesn't matter
# here — workload is always included).

set -uo pipefail

BINARY="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SMOKE_DIR="$(mktemp -d /tmp/crdb-smoketest-XXXXXX)"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

check() {
  local label="$1"; shift
  if "$@" 2>/dev/null; then
    green "  PASS  $label"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $label"
    FAIL=$((FAIL + 1))
  fi
}

check_file_nonempty() {
  local label="$1" path="$2"
  if [[ -s "$path" ]]; then
    green "  PASS  $label"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $label  (missing or empty: $path)"
    FAIL=$((FAIL + 1))
  fi
}

check_output_contains() {
  local label="$1" path="$2" pattern="$3"
  if grep -qE "$pattern" "$path" 2>/dev/null; then
    green "  PASS  $label"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $label  (pattern '$pattern' not found in $path)"
    FAIL=$((FAIL + 1))
  fi
}

cleanup() {
  # Kill any stray nodes from a failed run.
  pkill -f "cockroach start" 2>/dev/null || true
  rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
echo "=== 1. Prerequisites ==="

# Resolve binary.
if [[ -z "$BINARY" ]]; then
  if [[ -x "$SCRIPT_DIR/cockroach" ]]; then
    BINARY="$SCRIPT_DIR/cockroach"
  elif command -v cockroach &>/dev/null; then
    BINARY="$(command -v cockroach)"
  fi
fi
check "cockroach binary exists and is executable" test -x "$BINARY"
check "python3 available"                          command -v python3

# ---------------------------------------------------------------------------
# 2. Script syntax
# ---------------------------------------------------------------------------
echo ""
echo "=== 2. Script syntax ==="

check "phase2_scenario1.sh"    bash -n "$SCRIPT_DIR/phase2_scenario1.sh"
check "setup_sim_disks.sh"     bash -n "$SCRIPT_DIR/sim_disk/setup_sim_disks.sh"
check "teardown_sim_disks.sh"  bash -n "$SCRIPT_DIR/sim_disk/teardown_sim_disks.sh"
check "run_aws_bench.sh"       bash -n "$SCRIPT_DIR/sim_disk/aws/run_aws_bench.sh"
check "analyze_vars.py syntax" python3 -m py_compile "$SCRIPT_DIR/analyze_vars.py"

# ---------------------------------------------------------------------------
# 3. Full local run (condensed)
# ---------------------------------------------------------------------------
echo ""
echo "=== 3. Full local run (20 s measure, 10 s warmup, concurrency=16) ==="
echo "    Results → $SMOKE_DIR"
echo "    (this takes ~3–4 minutes)"
echo ""

PHASE2_OUT="$SMOKE_DIR/phase2.out"
set +e
RESULTS_DIR="$SMOKE_DIR" \
DURATION=20s \
WARMUP=10s \
CONCURRENCY=16 \
ALL_NODES=true \
  bash "$SCRIPT_DIR/phase2_scenario1.sh" "$BINARY" \
  >"$PHASE2_OUT" 2>&1
PHASE2_EXIT=$?
set -e

check "phase2_scenario1.sh exited 0" test "$PHASE2_EXIT" -eq 0

if [[ "$PHASE2_EXIT" -ne 0 ]]; then
  red ""
  red "phase2_scenario1.sh failed. Last 30 lines of output:"
  tail -30 "$PHASE2_OUT" | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
# 4. Output file validation
# ---------------------------------------------------------------------------
echo ""
echo "=== 4. Output files ==="

for scenario in baseline s1_p33 s1_p100 s2_p33 s2_p100; do
  check_file_nonempty "workload output:  ${scenario}.txt"           "$SMOKE_DIR/${scenario}.txt"
  check_file_nonempty "pre vars node 1:  pre_${scenario}_n1.vars"  "$SMOKE_DIR/pre_${scenario}_n1.vars"
  check_file_nonempty "post vars node 1: post_${scenario}_n1.vars" "$SMOKE_DIR/post_${scenario}_n1.vars"
done

# Summary table should have all five scenario rows.
for scenario in baseline s1_p33 s1_p100 s2_p33 s2_p100; do
  check_output_contains "summary row: $scenario" "$PHASE2_OUT" "^${scenario}"
done

# Workload should show non-zero throughput (ops/sec > 0) for baseline.
check_output_contains "baseline has non-zero throughput" \
  "$SMOKE_DIR/baseline.txt" "write"

# No ERROR lines in the phase2 output (settings errors show up as "Error").
check "no error lines in phase2 output" \
  bash -c "! grep -iE '^Error|^error:|ERROR:' '$PHASE2_OUT'"

# ---------------------------------------------------------------------------
# 5. analyze_vars.py
# ---------------------------------------------------------------------------
echo ""
echo "=== 5. analyze_vars.py ==="

ANALYZE_OUT="$SMOKE_DIR/analyze.out"
set +e
python3 "$SCRIPT_DIR/analyze_vars.py" \
  --results-dir "$SMOKE_DIR" \
  --nodes 3 \
  >"$ANALYZE_OUT" 2>&1
ANALYZE_EXIT=$?
set -e

check "analyze_vars.py exited 0" test "$ANALYZE_EXIT" -eq 0
check_file_nonempty "analyze_vars.py produced output" "$ANALYZE_OUT"
check_output_contains "latency table has baseline row" "$ANALYZE_OUT" "baseline"
check_output_contains "latency table has s1_p33 row"  "$ANALYZE_OUT" "s1_p33"

# avg commit latency for s1_p100 should be a number (not NaN/missing).
check_output_contains "s1_p100 avg latency is a number" \
  "$ANALYZE_OUT" "s1_p100.*[0-9]\.[0-9]"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
if [[ "$FAIL" -eq 0 ]]; then
  green "All $PASS checks passed."
else
  red   "$FAIL of $((PASS + FAIL)) checks failed."
  echo ""
  echo "Full phase2 output:   $PHASE2_OUT"
  echo "Full analyze output:  $ANALYZE_OUT"
  echo "(results dir kept for inspection: $SMOKE_DIR)"
  # Don't remove results dir on failure so the user can inspect.
  trap - EXIT
  pkill -f "cockroach start" 2>/dev/null || true
  exit 1
fi
