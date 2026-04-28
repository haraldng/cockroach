#!/usr/bin/env bash
# setup_ebs_disk.sh — one-time setup for an attached EBS volume on an EC2
# instance.  Formats the volume, mounts it, and configures the I/O scheduler
# for HDD.
#
# Must run as root (or via sudo).
#
# Usage:
#   sudo ./setup_ebs_disk.sh [block-device] [mount-point]
#
# Defaults:
#   block-device  /dev/xvdb   (first extra EBS volume on most x86 instances)
#   mount-point   /mnt/crdb-bench
#
# After this script completes, run:
#   ./run_real_disk_bench.sh ./cockroach
#
# Instance + EBS provisioning with roachprod (run this on your laptop first):
#   roachprod create $USER-real-disk --clouds=aws --nodes=1 \
#     --aws-machine-type=m6i.large \
#     --aws-ebs-volume-type=st1 --aws-ebs-volume-size=500 \
#     --lifetime=6h
#   roachprod run $USER-real-disk -- \
#     "curl -sSL <your-binary-url> -o cockroach && chmod +x cockroach"
#   roachprod run $USER-real-disk -- \
#     "sudo bash <(cat bench_tier_a/sim_disk/real_disk/setup_ebs_disk.sh)"
#
# Supported EBS types for meaningful quorum-sync signal:
#   st1  — Throughput Optimized HDD (≥500 GB); real ~10–25ms fsyncs under load
#   sc1  — Cold HDD; even slower, strongest signal
#   gp3  — General Purpose SSD (3000 IOPS / 125 MB/s baseline); ~1–3ms fsyncs;
#           moderate signal (+20–32% throughput)
#   gp2  — NOT recommended: burst credits inflate baseline throughput

set -euo pipefail

BLOCK_DEV="${1:-/dev/xvdb}"
MOUNT_POINT="${2:-/mnt/crdb-bench}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: this script must run as root" >&2
  exit 1
fi

# Safety check: refuse to format a device that already has a filesystem.
if blkid "$BLOCK_DEV" &>/dev/null; then
  echo "WARNING: $BLOCK_DEV already has a filesystem signature:"
  blkid "$BLOCK_DEV"
  echo ""
  read -r -p "Reformat and lose all existing data? [y/N] " CONFIRM
  if [[ "${CONFIRM,,}" != "y" ]]; then
    echo "Aborting."
    exit 1
  fi
fi

echo "==> Formatting $BLOCK_DEV with ext4..."
mkfs.ext4 -F "$BLOCK_DEV"

echo "==> Mounting at $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT"
mount "$BLOCK_DEV" "$MOUNT_POINT"
chmod 777 "$MOUNT_POINT"

# ---------------------------------------------------------------------------
# I/O scheduler tuning for HDD.
# mq-deadline reduces request starvation and gives more predictable latency
# than the default kyber or none schedulers.
# ---------------------------------------------------------------------------
DEV_NAME="$(basename "$BLOCK_DEV")"
# Strip partition suffix if any (e.g. xvdb1 → xvdb).
BASE_DEV="${DEV_NAME%%[0-9]}"
SCHED_FILE="/sys/block/$BASE_DEV/queue/scheduler"
if [[ -f "$SCHED_FILE" ]]; then
  AVAILABLE=$(cat "$SCHED_FILE")
  if echo "$AVAILABLE" | grep -q "mq-deadline"; then
    echo "==> Setting I/O scheduler to mq-deadline on $BASE_DEV..."
    echo mq-deadline > "$SCHED_FILE"
  else
    echo "    Note: mq-deadline not available for $BASE_DEV ($AVAILABLE); leaving scheduler unchanged."
  fi
fi

# ---------------------------------------------------------------------------
# Probe fsync latency to confirm the disk is in the I/O path.
# ---------------------------------------------------------------------------
echo ""
echo "==> Probing fsync latency (20 × 4 KB writes on $MOUNT_POINT)..."
PROBE_MS=$(python3 - "$MOUNT_POINT" <<'PYEOF'
import time, os, sys, pathlib
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
python3 -c "
ms = float('${PROBE_MS}')
if ms < 0.5:
    print('    WARNING: latency looks like NVMe — quorum-sync may show no signal here.')
elif ms < 2.0:
    print(f'    Looks like gp3/SSD (~{ms:.1f}ms). Expect +20–32% throughput for s1_p33.')
else:
    print(f'    Looks like HDD/slow-EBS (~{ms:.1f}ms). Expect ≥+100% throughput for s1_p33.')
"

echo ""
echo "==> Disk ready at $MOUNT_POINT"
echo ""
echo "    Next step:"
echo "      DISK_PATH=$MOUNT_POINT ./sim_disk/real_disk/run_real_disk_bench.sh ./cockroach"
