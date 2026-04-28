#!/usr/bin/env bash
# run_real_disk_bench.sh — run the quorum-sync scenario matrix against a real
# disk (HDD or slow EBS) without any dm-delay or cgroups simulation.
#
# Three CRDB nodes are started locally, each with its store directory under
# DISK_PATH.  All three stores share the same physical disk, maximising
# write-bandwidth contention — exactly the bottleneck quorum-sync targets.
#
# Usage:
#   DISK_PATH=/mnt/crdb-bench ./run_real_disk_bench.sh <path-to-cockroach-binary>
#
# The script does NOT require root and does NOT modify disk layout.  It assumes
# the disk at DISK_PATH is already mounted and writable.
#
# Recommended hardware (signal strongest to weakest):
#   st1 EBS 500 GB  — real rotational HDD EBS; ~10–25ms fsyncs under load;
#                     expected ≥+100% s1_p33 workload throughput
#   d3.xlarge local HDD — NL-SAS instance store; similar to st1 EBS
#   gp3 EBS 3000 IOPS/125 MB/s — cloud SSD baseline; ~1–3ms fsyncs;
#                     expected +20–32% s1_p33 workload throughput
#
# NVMe / gp3-max / local instance NVMe will show near-zero or negative signal
# (fsync < 0.5ms; below the feature's break-even point).
#
# To provision a suitable single-node cluster with roachprod:
#   roachprod create $USER-real-disk --clouds=aws --nodes=1 \
#     --aws-machine-type=m6i.large \
#     --aws-ebs-volume-type=st1 --aws-ebs-volume-size=500 \
#     --lifetime=6h
#   roachprod run $USER-real-disk -- "sudo mkfs.ext4 /dev/xvdb && sudo mount /dev/xvdb /mnt/crdb-bench && sudo chmod 777 /mnt/crdb-bench"
#
# Then on the remote VM:
#   ./sim_disk/real_disk/run_real_disk_bench.sh ./cockroach
#
# Optional env overrides:
#   DISK_PATH        Directory under which n1/, n2/, n3/ store dirs are created.
#                    Must already exist. Default: /mnt/crdb-bench
#   RESULTS_DIR      Where to write .txt workload logs and .vars metric snapshots.
#                    Default: $DISK_PATH/results-<timestamp>
#   DURATION         Workload measurement window. Default: 5m
#   WARMUP           Workload warmup before measurement. Default: 2m
#   CONCURRENCY      kv workload concurrency. Default: 256
#   BLOCK_BYTES      kv workload block size in bytes. Default: 128

set -euo pipefail

BINARY="${1:?usage: $0 <path-to-cockroach-binary>}"
BENCH_DIR="${BENCH_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
DISK_PATH="${DISK_PATH:-/mnt/crdb-bench}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_DIR="${RESULTS_DIR:-$DISK_PATH/results-$RUN_ID}"

# ---------------------------------------------------------------------------
# Resolve binary path (same logic as run_tiered_bench.sh).
# ---------------------------------------------------------------------------
if [[ -d "$BINARY" ]]; then
  if [[ -x "$BINARY/cockroach" ]]; then
    BINARY="$BINARY/cockroach"
  else
    echo "error: binary argument is a directory: $BINARY" >&2
    echo "       pass the cockroach binary path, e.g. $BINARY/cockroach" >&2
    exit 1
  fi
fi
if [[ ! -x "$BINARY" ]]; then
  echo "error: cockroach binary is not executable: $BINARY" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate disk path.
# ---------------------------------------------------------------------------
if [[ ! -d "$DISK_PATH" ]]; then
  echo "error: DISK_PATH does not exist: $DISK_PATH" >&2
  echo "       Mount your disk first (e.g. sudo mount /dev/xvdb $DISK_PATH)" >&2
  echo "       Or run sim_disk/real_disk/setup_ebs_disk.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Probe fsync latency to characterise the disk before committing to a full run.
# ---------------------------------------------------------------------------
echo ""
echo "==> Probing fsync latency on $DISK_PATH (20 × 4 KB writes)..."
PROBE_MS=$(python3 - "$DISK_PATH" <<'PYEOF'
import time, os, sys, tempfile, pathlib

path = pathlib.Path(sys.argv[1]) / ".probe"
with open(path, "wb") as f:
    t0 = time.monotonic()
    for _ in range(20):
        f.write(b"x" * 4096)
        os.fsync(f.fileno())
    elapsed = time.monotonic() - t0
path.unlink(missing_ok=True)
print(f"{elapsed/20*1000:.1f}")
PYEOF
)

echo "    fsync probe: ${PROBE_MS} ms per call"

# Warn if the disk looks like NVMe (< 0.5ms); likely no feature signal.
python3 -c "
import sys
ms = float('${PROBE_MS}')
if ms < 0.5:
    print('    WARNING: fsync latency is < 0.5ms — this looks like local NVMe.')
    print('             The quorum-sync feature is unlikely to show a win.')
    print('             For meaningful results, use st1/sc1 EBS or a d3 HDD instance.')
elif ms < 2.0:
    print(f'    disk tier: cloud SSD (gp3-base analogue, ~{ms:.1f}ms)')
    print('    Expected: +20–32% workload throughput for s1_p33')
elif ms < 6.0:
    print(f'    disk tier: slow SSD / HDD (ssd-slow/hdd analogue, ~{ms:.1f}ms)')
    print('    Expected: +32–100%+ workload throughput for s1_p33')
else:
    print(f'    disk tier: HDD (hdd analogue, ~{ms:.1f}ms)')
    print('    Expected: ≥+100% workload throughput for s1_p33')
"

echo ""

# ---------------------------------------------------------------------------
# Create per-node store directories.
# ---------------------------------------------------------------------------
NODE1_STORE="$DISK_PATH/n1"
NODE2_STORE="$DISK_PATH/n2"
NODE3_STORE="$DISK_PATH/n3"
mkdir -p "$NODE1_STORE" "$NODE2_STORE" "$NODE3_STORE"
mkdir -p "$RESULTS_DIR"

echo "==> Store paths:"
echo "    node 1: $NODE1_STORE"
echo "    node 2: $NODE2_STORE"
echo "    node 3: $NODE3_STORE"
echo "==> Results:    $RESULTS_DIR"
echo ""

# ---------------------------------------------------------------------------
# Run the full 5-scenario matrix via phase2_scenario1.sh.
# NODE_STORE_* tells the script where each node's store lives.
# IMG_DIR is deliberately unset so cgroup attachment is skipped.
# ---------------------------------------------------------------------------
unset IMG_DIR

NODE_STORE_1="$NODE1_STORE" \
NODE_STORE_2="$NODE2_STORE" \
NODE_STORE_3="$NODE3_STORE" \
RESULTS_DIR="$RESULTS_DIR" \
  "$BENCH_DIR/phase2_scenario1.sh" "$BINARY"

echo ""
echo "==> Real-disk benchmark complete."
echo "    Results: $RESULTS_DIR"
echo ""
echo "    Analyse with:"
echo "      python3 $BENCH_DIR/analyze_vars.py --results-dir $RESULTS_DIR --nodes 3"
echo ""
echo "    Interpretation:"
echo "      design-1 capture  = (s1_p33 - baseline) / (s1_p100 - baseline)"
echo "      design-2 capture  = (s2_p33 - baseline) / (s2_p100 - baseline)"
echo "      If D1 capture ≥ 0.25 and s1_p33 throughput ≥ +20%: feature has real signal."
