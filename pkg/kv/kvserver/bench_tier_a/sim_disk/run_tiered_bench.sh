#!/usr/bin/env bash
# Sweeps the four disk-latency tiers and runs the full phase2_scenario1.sh
# matrix under each tier.  Each iteration is an isolated setup → bench →
# teardown cycle so LSM state does not drift between tiers.
#
# Usage: sudo ./sim_disk/run_tiered_bench.sh <path-to-cockroach-binary>
#
# Run from the bench_tier_a/ directory, or set BENCH_DIR explicitly.
# If the source checkout is `~/cockroach`, do not pass `~/cockroach` here; pass
# the binary inside it (`~/cockroach/cockroach`) or a copied binary
# (`~/bench_tier_a/cockroach`).
#
# Results land in a timestamped directory:
#   phase2_scenario1_results/run-YYYYmmdd-HHMMSS/{nvme,ssd-fast,ssd-slow,hdd}/.
# Set RESULTS_ROOT to override the run directory.
# Total runtime: ~2h (4 tiers × 5 scenarios × ~7 min warmup+measure each).
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt-get install -y dmsetup util-linux e2fsprogs
#   # cgroups v2 must be active:
#   mount | grep cgroup2          # must show a cgroup2 line
#   cat /sys/fs/cgroup/cgroup.controllers  # must include "io"

set -euo pipefail

BINARY="${1:?usage: sudo $0 <path-to-cockroach-binary>}"
BENCH_DIR="${BENCH_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SIM_DIR="$BENCH_DIR/sim_disk"
export IMG_DIR="${IMG_DIR:-/tmp/crdb-sim}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULTS_ROOT="${RESULTS_ROOT:-$BENCH_DIR/phase2_scenario1_results/run-$RUN_ID}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: this script must run as root (dm-delay and cgroups require it)" >&2
  exit 1
fi

if [[ -d "$BINARY" ]]; then
  if [[ -x "$BINARY/cockroach" ]]; then
    BINARY="$BINARY/cockroach"
  else
    echo "error: binary argument is a directory: $BINARY" >&2
    echo "       pass the cockroach binary path, e.g. $BINARY/cockroach or ~/bench_tier_a/cockroach" >&2
    exit 1
  fi
fi
if [[ ! -x "$BINARY" ]]; then
  echo "error: cockroach binary is not executable: $BINARY" >&2
  exit 1
fi

mkdir -p "$RESULTS_ROOT"
echo "==> Results root: $RESULTS_ROOT"

# Tier definitions: "name delay_ms write_mb_s"
# delay_ms  — dm-delay write latency added to each block-layer completion
# write_mb_s — cgroups v2 io.max wbps cap (0 = uncapped)
#
# These four tiers span the range from "feature has no signal" (nvme, ~0.1ms
# native) to "feature has maximum effect" (hdd, ~8ms, ~100 MB/s).
TIERS=(
  "nvme      0   0"
  "ssd-fast  1   400"
  "ssd-slow  3   240"
  "hdd       8   100"
)

for tier_spec in "${TIERS[@]}"; do
  read -r TIER DELAY_MS WRITE_MB <<< "$tier_spec"

  echo ""
  echo "============================================"
  echo "Tier: $TIER  (${DELAY_MS}ms write delay, ${WRITE_MB:-0} MB/s write cap)"
  echo "============================================"

  # Set up simulated disks for this tier.
  "$SIM_DIR/setup_sim_disks.sh" "$DELAY_MS" "$WRITE_MB"

  # Verify the simulation before spending ~30 minutes on a full matrix run.
  # A 20-fsync probe at 4KB should take ~(delay_ms × 20)ms; if it completes in
  # <5ms total regardless of delay_ms the dm device is not in the I/O path.
  echo "==> Verifying fsync latency on /mnt/crdb1..."
  PROBE_MS=$(python3 - <<'PYEOF'
import time, os
with open("/mnt/crdb1/probe", "wb") as f:
    t0 = time.monotonic()
    for _ in range(20):
        f.write(b"x" * 4096)
        os.fsync(f.fileno())
    elapsed = time.monotonic() - t0
print(f"{elapsed/20*1000:.1f}")
PYEOF
)
  echo "    fsync probe: ${PROBE_MS}ms per call (expected ≥ ${DELAY_MS}ms)"
  # Warn but don't abort — on 0ms tier (nvme) the probe will show ~0ms.
  if python3 -c "import sys; sys.exit(0 if float('${PROBE_MS}') >= ${DELAY_MS} * 0.8 or ${DELAY_MS} == 0 else 1)"; then
    echo "    OK"
  else
    echo "    WARNING: measured latency is below expected — dm-delay may not be in the I/O path."
    echo "    Continuing anyway; results for this tier may be indistinguishable from nvme."
  fi

  # Tell phase2_scenario1.sh where each node's store lives.
  export NODE_STORE_1=/mnt/crdb1
  export NODE_STORE_2=/mnt/crdb2
  export NODE_STORE_3=/mnt/crdb3

  # Also export IMG_DIR so start_cluster() can find cgroup files when attaching.
  export IMG_DIR

  # Redirect results into a per-run, per-tier subdirectory.
  export RESULTS_DIR="$RESULTS_ROOT/$TIER"
  mkdir -p "$RESULTS_DIR"

  # Run the full 5-scenario matrix (baseline, s1_p33, s1_p100, s2_p33, s2_p100).
  "$BENCH_DIR/phase2_scenario1.sh" "$BINARY"

  # Tear down disks before the next tier to ensure clean state.
  "$SIM_DIR/teardown_sim_disks.sh"
done

echo ""
echo "==> All tiers complete."
echo "    Results: $RESULTS_ROOT/{nvme,ssd-fast,ssd-slow,hdd}/"
echo ""
echo "    Interpretation (per tier):"
echo "      design-1 capture  = (s1_p33 - baseline) / (s1_p100 - baseline)"
echo "      design-2 capture  = (s2_p33 - baseline) / (s2_p100 - baseline)"
echo "      write-BW share    = (s2_p33 - s1_p33)  / (s2_p100 - baseline)"
echo "      S1 ceiling check  : s1_p100 ≈ s2_p100  (both disable fsyncs)"
