#!/usr/bin/env bash
# Phase 2 Scenario 1 — IOPS wall benchmark
# Matrix: baseline, s2_p33 (S2 @ p=1/3), s2_p100 (U = S2 @ p=1.0)
# Workload: kv0, 128-byte blocks, concurrency=256, 3-node local cluster
#
# Usage: ./phase2_scenario1.sh <path-to-cockroach-binary>
# Results written to phase2_scenario1_results/ alongside this script

set -euo pipefail

BINARY="${1:-./cockroach}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/phase2_scenario1_results"
CLUSTER_DATA="$RESULTS_DIR/cluster-data"
LOG_DIR="$RESULTS_DIR/logs"
DURATION="5m"
WARMUP="2m"
CONCURRENCY=256
BLOCK_BYTES=128

mkdir -p "$RESULTS_DIR" "$LOG_DIR"

PORTS=(26257 26258 26259)
HTTP_PORTS=(8080 8081 8082)

# Set ALL_NODES=true before running to snapshot all three nodes instead of only
# node 1. The analyze_vars.py --nodes 3 flag then sums them for cluster-wide
# histograms. Single-node snapshots are fine for ratios; all-nodes is better
# for absolute commit counts and latency percentiles under skewed leadership.
ALL_NODES="${ALL_NODES:-false}"

pg_url() {
  echo "postgresql://root@localhost:26257?sslmode=disable"
}

declare -A NODE_PIDS

start_cluster() {
  echo "==> Starting 3-node cluster..."
  rm -rf "$CLUSTER_DATA"
  for i in 0 1 2; do
    node=$((i+1))
    # Allow the caller (e.g. run_tiered_bench.sh) to redirect each node's store
    # to a separate dm-delay device so nodes don't share a physical disk. Falls
    # back to the default per-node data directory when not set.
    _store_var="NODE_STORE_${node}"
    _store="${!_store_var:-$CLUSTER_DATA/$node}"
    mkdir -p "$_store"
    "$BINARY" start --insecure \
      --listen-addr="localhost:${PORTS[$i]}" \
      --http-addr="localhost:${HTTP_PORTS[$i]}" \
      --store="$_store" \
      --join="localhost:26257,localhost:26258,localhost:26259" \
      --log-dir="$LOG_DIR/node$node" \
      >"$LOG_DIR/node$node.stdout" 2>&1 &
    NODE_PIDS[$node]=$!
    echo "  node $node PID ${NODE_PIDS[$node]}"
  done
  sleep 5
  "$BINARY" init --insecure --host=localhost:26257 >/dev/null 2>&1 || true
  sleep 5

  # If a cgroups v2 bandwidth cap was set up by setup_sim_disks.sh, move each
  # node process into its cgroup now that PIDs are known.
  _img_dir="${IMG_DIR:-}"
  if [[ -n "$_img_dir" ]]; then
    for node in 1 2 3; do
      _cgroup_file="$_img_dir/node${node}.cgroup"
      if [[ -f "$_cgroup_file" ]]; then
        _cgroup=$(cat "$_cgroup_file")
        echo "${NODE_PIDS[$node]}" > "$_cgroup/cgroup.procs" 2>/dev/null || true
        echo "  node${node}: moved PID ${NODE_PIDS[$node]} into cgroup $_cgroup"
      fi
    done
  fi

  echo "==> Cluster up."
}

stop_cluster() {
  echo "==> Stopping cluster..."
  pkill -f "cockroach start" 2>/dev/null || true
  sleep 3
}

# set_unsafe_cluster_setting <setting> <value>
# Uses Python3 (stdlib only) to open a single PostgreSQL connection, attempt the
# SET, capture the session-specific interlock key from the error, then retry —
# all in one session so the key matches.
set_unsafe_cluster_setting() {
  local setting="$1"
  local value="$2"
  python3 - localhost 26257 "$setting" "$value" <<'PYEOF'
import socket, struct, re, sys

def pg_connect(host, port):
    sock = socket.create_connection((host, port))
    params = b'user\x00root\x00database\x00defaultdb\x00\x00'
    length = 4 + 4 + len(params)
    sock.sendall(struct.pack('>II', length, 196608) + params)
    return sock

def recv_msg(sock):
    header = b''
    while len(header) < 5:
        header += sock.recv(5 - len(header))
    t = chr(header[0])
    n = struct.unpack('>I', header[1:5])[0] - 4
    body = b''
    while len(body) < n:
        body += sock.recv(n - len(body))
    return t, body

def drain(sock):
    msgs = []
    while True:
        t, b = recv_msg(sock)
        msgs.append((t, b))
        if t == 'Z':
            break
    return msgs

def run_query(sock, sql):
    enc = sql.encode() + b'\x00'
    sock.sendall(b'Q' + struct.pack('>I', len(enc) + 4) + enc)
    return drain(sock)

def error_detail(msgs):
    for t, b in msgs:
        if t == 'E':
            i = 0
            while i < len(b):
                ft = b[i]; i += 1
                if ft == 0:
                    break
                end = b.index(0, i)
                if ft == ord('D'):
                    return b[i:end].decode()
                i = end + 1
    return None

host, port, setting, value = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
sock = pg_connect(host, port)
drain(sock)  # consume startup messages

sql = f"SET CLUSTER SETTING {setting} = {value}"
msgs = run_query(sock, sql)

detail = error_detail(msgs)
if detail:
    m = re.search(r'key: ([A-Za-z0-9+/=]+)', detail)
    if not m:
        print(f"Error: {detail}", file=sys.stderr)
        sys.exit(1)
    key = m.group(1)
    run_query(sock, f"SET unsafe_setting_interlock_key = '{key}'")
    msgs2 = run_query(sock, sql)
    err = error_detail(msgs2)
    if err:
        print(f"Error setting {setting}: {err}", file=sys.stderr)
        sys.exit(1)

sock.sendall(b'X' + struct.pack('>I', 4))
sock.close()
PYEOF
}

apply_settings() {
  local design="$1"
  echo "==> Applying cluster settings for: $design"
  case "$design" in
    baseline)
      # RESET never triggers the interlock — safe for all unsafe settings.
      "$BINARY" sql --insecure --host=localhost:26257 -e "
        RESET CLUSTER SETTING kv.raft_log.disable_synchronization_unsafe;
        RESET CLUSTER SETTING kv.raft_log.simulated_quorum_skip_probability;
        RESET CLUSTER SETTING kv.raft_log.simulated_wal_write_skip_probability;
      " >/dev/null
      ;;
    s2_p100)
      # U — upper bound: every replica skips the fsync on every Raft log append
      # (entries are still written to the WAL; only flush+fsync is suppressed).
      # This is the ceiling on fsync cost for any Raft-WAL feature.
      #
      # NOTE: S2 with p=1.0 (skip the entire write, not just the fsync) is
      # fatally unstable for runs longer than a few minutes: with zero entries
      # ever persisted anywhere, Raft log truncation (which requires reading
      # entries back for snapshotting) panics and crashes all nodes. So we use
      # disable_synchronization_unsafe=true here, which skips fsyncs while
      # keeping WAL bytes intact — the only runtime-stable upper bound.
      "$BINARY" sql --insecure --host=localhost:26257 -e "
        RESET CLUSTER SETTING kv.raft_log.simulated_quorum_skip_probability;
        RESET CLUSTER SETTING kv.raft_log.simulated_wal_write_skip_probability;
      " >/dev/null
      set_unsafe_cluster_setting "kv.raft_log.disable_synchronization_unsafe" "true"
      ;;
    s1_p33)
      # S1 at N=3, Q=2: design-(1), skip probability = (N-Q)/N = 1/3.
      # Entries are still written to the WAL; only the fsync barrier is skipped.
      # Compare against s2_p33 to isolate write-bandwidth vs fsync-latency gains.
      "$BINARY" sql --insecure --host=localhost:26257 -e "
        RESET CLUSTER SETTING kv.raft_log.disable_synchronization_unsafe;
        RESET CLUSTER SETTING kv.raft_log.simulated_wal_write_skip_probability;
      " >/dev/null
      set_unsafe_cluster_setting "kv.raft_log.simulated_quorum_skip_probability" "0.333"
      ;;
    s1_p100)
      # S1 ceiling: every replica skips the fsync on every Raft log append via
      # the per-entry knob (simulated_quorum_skip_probability=1.0). Entries are
      # still written. Compare against s2_p100 (disable_synchronization_unsafe)
      # to verify the two design-(1) mechanisms produce equivalent results.
      "$BINARY" sql --insecure --host=localhost:26257 -e "
        RESET CLUSTER SETTING kv.raft_log.disable_synchronization_unsafe;
        RESET CLUSTER SETTING kv.raft_log.simulated_wal_write_skip_probability;
      " >/dev/null
      set_unsafe_cluster_setting "kv.raft_log.simulated_quorum_skip_probability" "1.0"
      ;;
    s2_p33)
      # S2 at N=3, Q=2: skip probability = (N-Q)/N = 1/3.
      "$BINARY" sql --insecure --host=localhost:26257 -e "
        RESET CLUSTER SETTING kv.raft_log.disable_synchronization_unsafe;
        RESET CLUSTER SETTING kv.raft_log.simulated_quorum_skip_probability;
      " >/dev/null
      set_unsafe_cluster_setting "kv.raft_log.simulated_wal_write_skip_probability" "0.333"
      ;;
  esac
}

run_workload() {
  local label="$1"
  local outfile="$RESULTS_DIR/${label}.txt"
  echo "==> Warming up ($WARMUP)..."
  "$BINARY" workload run kv \
    --duration="$WARMUP" \
    --concurrency="$CONCURRENCY" \
    --min-block-bytes="$BLOCK_BYTES" \
    --max-block-bytes="$BLOCK_BYTES" \
    --histograms="$RESULTS_DIR/${label}_warmup_hist.json" \
    "$(pg_url)" >/dev/null 2>&1 || true

  echo "==> Measuring ($DURATION)..."
  "$BINARY" workload run kv \
    --duration="$DURATION" \
    --concurrency="$CONCURRENCY" \
    --min-block-bytes="$BLOCK_BYTES" \
    --max-block-bytes="$BLOCK_BYTES" \
    --histograms="$RESULTS_DIR/${label}_hist.json" \
    "$(pg_url)" 2>&1 | tee "$outfile"
  echo "    => results in $outfile"
}

# Snapshot the full Prometheus vars page (cumulative counters). Paired calls of
# snapshot_vars "pre_<design>" before the workload and "post_<design>" after it
# let us compute per-run deltas at summary time — since the cluster is shared
# across all three designs, the raw counter values alone are not per-run.
snapshot_vars() {
  local tag="$1"
  # raft_process_logcommit_latency: Raft-log commit path specifically (entries
  # + HardState → stable storage). Its _count is the per-run Raft fsync count.
  # Unlike storage_wal_fsync_latency_count (Pebble store-wide), this metric
  # isolates the exact path that S1/S2 are designed to accelerate.
  local filter="storage_wal|raft_process_commandcommit|raft_process_logcommit|storage_wal_fsync"
  if [[ "$ALL_NODES" == "true" ]]; then
    local n=1
    for port in "${HTTP_PORTS[@]}"; do
      curl -s "http://localhost:${port}/_status/vars" 2>/dev/null \
        | grep -E "$filter" \
        > "$RESULTS_DIR/${tag}_n${n}.vars" || true
      n=$((n + 1))
    done
    # Also write a merged single-node-compatible file for the legacy awk summary.
    cat "$RESULTS_DIR/${tag}_n1.vars" > "$RESULTS_DIR/${tag}.vars" 2>/dev/null || true
  else
    curl -s "http://localhost:8080/_status/vars" 2>/dev/null \
      | grep -E "$filter" \
      > "$RESULTS_DIR/${tag}.vars" || true
  fi
}

collect_metrics() {
  local label="$1"
  snapshot_vars "post_${label}"
  # Keep a legacy cumulative file for backwards compatibility with old analysis
  # scripts; the authoritative per-run numbers come from pre_*/post_* deltas.
  cp "$RESULTS_DIR/post_${label}.vars" "$RESULTS_DIR/${label}_metrics.txt"
  echo "    => metrics in $RESULTS_DIR/pre_${label}.vars, post_${label}.vars"
}

echo "=== Phase 2 Scenario 1: IOPS Wall ==="
echo "Binary: $BINARY"
echo "Concurrency: $CONCURRENCY, block: ${BLOCK_BYTES}B, warmup: $WARMUP, measure: $DURATION"
echo "Results: $RESULTS_DIR"
echo ""

# Initialize workload data once
start_cluster
echo "==> Initializing kv workload..."
"$BINARY" workload init kv "$(pg_url)" >/dev/null 2>&1 || true
sleep 3

for design in baseline s1_p33 s1_p100 s2_p33 s2_p100; do
  echo ""
  echo "--- $design ---"
  apply_settings "$design"
  sleep 10  # let settings propagate
  snapshot_vars "pre_${design}"
  run_workload "$design"
  collect_metrics "$design"
done

stop_cluster

echo ""
echo "=== Summary — workload (per 5-min measurement) ==="
# The workload run prints two final blocks at the end of each file:
#   _elapsed___errors_____ops(total)___ops/sec(cum)__avg(ms)__p50__p95__p99__pMax__total
#   <values> write
#   _elapsed___errors_____ops(total)___ops/sec(cum)__avg(ms)__p50__p95__p99__pMax__result
#   <values>
# Grab the header+value pair for __total (first aggregate block) from each file.
printf '\n%-10s %12s %12s %8s %8s %8s %8s %8s\n' \
  "scenario" "ops(total)" "ops/sec" "avg(ms)" "p50" "p95" "p99" "pMax"
for design in baseline s1_p33 s1_p100 s2_p33 s2_p100; do
  line="$(awk '
    /__total$/ { getline data; print data; exit }
  ' "$RESULTS_DIR/${design}.txt" 2>/dev/null)"
  if [[ -z "$line" ]]; then
    echo "  $design: (see $RESULTS_DIR/${design}.txt)"
    continue
  fi
  # Columns: elapsed errors ops(total) ops/sec(cum) avg p50 p95 p99 pMax kind
  read -r _elapsed _errors ops_total ops_sec avg p50 p95 p99 pmax _kind <<< "$line"
  printf '%-10s %12s %12s %8s %8s %8s %8s %8s\n' \
    "$design" "$ops_total" "$ops_sec" "$avg" "$p50" "$p95" "$p99" "$pmax"
done

echo ""
echo "=== Summary — server metrics (per-run deltas over warmup+measure) ==="
# Extract a scalar counter value from a saved /_status/vars snapshot.
# Takes only the first label-set match (store="1",node_id="1" on node 1).
vars_scalar() {
  local file="$1" metric="$2"
  awk -v m="$metric" '
    $0 ~ "^"m"\\{" { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.e+-]+$/) { print $i; exit } }
  ' "$file" 2>/dev/null
}

printf '\n%-10s %12s %10s %8s %10s %12s %12s %12s\n' \
  "scenario" "WAL_GB" "fsyncs" "B/op" "fsyncs/op" "RaftCommits" "commits/op" "avgCommit(ms)"
for design in baseline s1_p33 s1_p100 s2_p33 s2_p100; do
  pre="$RESULTS_DIR/pre_${design}.vars"
  post="$RESULTS_DIR/post_${design}.vars"
  if [[ ! -f "$pre" || ! -f "$post" ]]; then
    echo "  $design: (no pre/post snapshots — older run, use python analyzer)"
    continue
  fi
  # Pebble-level (store-wide) — noisy, includes state-machine writes.
  b0=$(vars_scalar "$pre"  storage_wal_bytes_written)
  b1=$(vars_scalar "$post" storage_wal_bytes_written)
  f0=$(vars_scalar "$pre"  storage_wal_fsync_latency_count)
  f1=$(vars_scalar "$post" storage_wal_fsync_latency_count)
  # Raft-log-specific: count + sum of time spent (ns) per logcommit call.
  # Each call commits >=1 entries + HardState; sum/count = avg commit latency.
  lc0=$(vars_scalar "$pre"  raft_process_logcommit_latency_count)
  lc1=$(vars_scalar "$post" raft_process_logcommit_latency_count)
  ls0=$(vars_scalar "$pre"  raft_process_logcommit_latency_sum)
  ls1=$(vars_scalar "$post" raft_process_logcommit_latency_sum)
  ops_line="$(awk '/__total$/ { getline d; print d; exit }' "$RESULTS_DIR/${design}.txt")"
  read -r _e _err ops_total _rest <<< "$ops_line"
  awk -v name="$design" \
      -v b0="$b0" -v b1="$b1" -v f0="$f0" -v f1="$f1" \
      -v lc0="$lc0" -v lc1="$lc1" -v ls0="$ls0" -v ls1="$ls1" \
      -v ops="$ops_total" 'BEGIN {
    dbytes = b1 - b0
    dfsync = f1 - f0
    dlc    = lc1 - lc0
    dls    = ls1 - ls0
    est_ops = ops * 7 / 5  # pre/post bracket warmup+measure; ops_total is 5m
    avg_commit_ms = (dlc > 0 ? (dls / dlc) / 1e6 : 0)
    printf "%-10s %12.2f %10.0f %8.0f %10.4f %12.0f %12.4f %12.3f\n",
      name, dbytes/1e9, dfsync,
      (est_ops>0 ? dbytes/est_ops : 0),
      (est_ops>0 ? dfsync/est_ops : 0),
      dlc,
      (est_ops>0 ? dlc/est_ops : 0),
      avg_commit_ms
  }'
done

cat <<'NOTE'

Counters are from node 1 only (single-node sample). kv0 spreads leadership
across all three nodes, so node 1 sees roughly N/3 of the work; compare ratios
across scenarios rather than absolute per-op values.

Column meanings:
  WAL_GB         Pebble WAL bytes written on node 1 (entries + state machine + rotations)
  fsyncs         Pebble WAL fsyncs on node 1 (store-wide; NOT Raft-log-specific)
  RaftCommits    raft.process.logcommit.latency _count: number of Raft-log
                 commit calls (entries + HardState). This IS the Raft-log-
                 specific fsync-path count.
  commits/op     RaftCommits / est_ops over the 7-min pre/post window
  avgCommit(ms)  avg time per Raft-log commit call (sum / count, in ms).
                 This is the key "fsync-cost" metric: S1/S2 should lower it,
                 U (no-fsync) should be the floor.

Design-1 capture (fsync savings at p=1/3):  (s1_p33 - baseline) / (s1_p100 - baseline)
Design-2 capture (write+fsync savings at p=1/3):  (s2_p33 - baseline) / (s2_p100 - baseline)
Write-bandwidth share of D2 win:  (s2_p33 - s1_p33) / (s2_p100 - baseline)
Verify S1 mechanisms agree: s1_p100 ≈ s2_p100 (both are design-1 ceiling, different knobs)

For per-Raft commit latency percentiles (p50/p95/p99) from histogram deltas run:

  python3 bench_tier_a/analyze_vars.py

Or with all-nodes capture (re-run with ALL_NODES=true for _n1/_n2/_n3 files):

  ALL_NODES=true ./phase2_scenario1.sh <binary>
  python3 bench_tier_a/analyze_vars.py --nodes 3
NOTE
