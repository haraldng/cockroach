#!/usr/bin/env bash
# Creates three simulated block devices for use as per-node CockroachDB stores.
#
# Usage: sudo ./setup_sim_disks.sh <delay_ms> [<write_mb_per_sec>]
#
# Produces:
#   /mnt/crdb{1,2,3}    ext4 filesystems on dm-delay devices
#   $IMG_DIR/node{1,2,3}.cgroup  (only when write_mb_per_sec > 0)
#
# Run teardown_sim_disks.sh to clean up.
#
# Why dm-delay and not direct loopback?  A raw loop device passes writes through
# to the host page cache and its fsyncs complete in ~0.1ms on any NVMe host —
# indistinguishable from a real NVMe for our purposes. dm-delay intercepts the
# block-layer completion and holds it for <delay_ms> milliseconds, faithfully
# modeling the latency of an HDD or remote-disk tier without requiring real
# hardware. The latency affects fdatasync / fsync because those block on the
# completion of in-flight writes — which dm-delay now holds.

set -euo pipefail

DELAY_MS="${1:?usage: sudo $0 <delay_ms> [write_mb_per_sec]}"
WRITE_MB="${2:-0}"
IMG_SIZE_MB="${IMG_SIZE_MB:-10240}"   # 10 GB per node; override for longer runs
IMG_DIR="${IMG_DIR:-/tmp/crdb-sim}"

mkdir -p "$IMG_DIR"

declare -a LOOP_DEVS
NODE_PIDS_FILE="$IMG_DIR/node_pids"

for node in 1 2 3; do
  IMG="$IMG_DIR/node${node}.img"
  DEV_NAME="crdb${node}"
  MNT="/mnt/crdb${node}"

  # Create backing file; skip if already present (allows re-running setup after
  # a partial teardown without re-allocating the full image).
  if [[ ! -f "$IMG" ]]; then
    echo "==> Creating ${IMG_SIZE_MB}MB image for node ${node}..."
    fallocate -l "${IMG_SIZE_MB}M" "$IMG"
  fi

  # Attach loopback device.
  LOOP=$(losetup -f --show "$IMG")
  LOOP_DEVS[$node]="$LOOP"
  echo "  node${node}: loop $LOOP"

  # Build dm-delay target.
  # Format: <start_sector> <num_sectors> delay <device> <offset> <read_ms> \
  #                                             [<device> <offset> <write_ms>]
  # Read delay is 0 — reads are not the bottleneck under any of our scenarios;
  # adding read delay would skew Raft log replay and HardState reads.
  SECTORS=$(blockdev --getsz "$LOOP")
  echo "0 $SECTORS delay $LOOP 0 0 $LOOP 0 $DELAY_MS" | dmsetup create "$DEV_NAME"
  echo "  node${node}: /dev/mapper/$DEV_NAME (${DELAY_MS}ms write delay, 0ms read delay)"

  # Format and mount.
  mkfs.ext4 -q -F /dev/mapper/"$DEV_NAME"
  mkdir -p "$MNT"
  mount /dev/mapper/"$DEV_NAME" "$MNT"
  chmod 777 "$MNT"
  echo "  node${node}: mounted at $MNT"

  # Optional cgroups v2 write-bandwidth cap.
  # We use the dm device's major:minor, not the loop device's, so the cap
  # applies after dm-delay and covers all writes to the virtual device.
  if [[ "${WRITE_MB}" -gt 0 ]]; then
    WRITE_BPS=$(( WRITE_MB * 1024 * 1024 ))
    DEV_MAJ_MIN=$(stat -L -c '%t:%T' /dev/mapper/"$DEV_NAME" 2>/dev/null || \
                  ls -l /dev/mapper/"$DEV_NAME" | awk '{print $5 ":" $6}' | tr -d ',')
    # stat -c '%t:%T' returns hex; convert to decimal for io.max.
    MAJ_HEX=$(echo "$DEV_MAJ_MIN" | cut -d: -f1)
    MIN_HEX=$(echo "$DEV_MAJ_MIN" | cut -d: -f2)
    MAJ=$(printf '%d' "0x${MAJ_HEX}")
    MIN=$(printf '%d' "0x${MIN_HEX}")

    CGROUP="/sys/fs/cgroup/crdb${node}"
    mkdir -p "$CGROUP"

    # cgroups v2 io.max requires the cgroup subtree_control to include "io".
    # If it doesn't, enable it from the root cgroup.
    if ! grep -q '\bio\b' /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
      echo "+io" | tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
    fi

    if echo "${MAJ}:${MIN} wbps=${WRITE_BPS}" > "$CGROUP/io.max" 2>/dev/null; then
      echo "$CGROUP" > "$IMG_DIR/node${node}.cgroup"
      echo "  node${node}: cgroup ${CGROUP}, io.max wbps=${WRITE_BPS} (${WRITE_MB} MB/s)"
    else
      echo "  node${node}: WARNING: cgroup io.max write failed for dm device ${MAJ}:${MIN}"
      echo "  node${node}: continuing without bandwidth cap; dm-delay latency is still active"
    fi
  fi
done

# Write loop device paths so teardown can find them without parsing dmsetup.
for node in 1 2 3; do
  echo "${LOOP_DEVS[$node]}" > "$IMG_DIR/node${node}.loop"
done

echo ""
echo "==> Simulation disks ready: /mnt/crdb{1,2,3}"
printf    "    %sms write latency" "$DELAY_MS"
if [[ "${WRITE_MB}" -gt 0 ]]; then
  printf ", %s MB/s write bandwidth cap" "$WRITE_MB"
else
  printf ", no bandwidth cap"
fi
echo ""
echo ""
echo "    To verify latency is in the I/O path, run:"
echo "      python3 -c \""
echo "        import time, os"
echo "        f = open('/mnt/crdb1/probe', 'wb')"
echo "        t0 = time.monotonic()"
echo "        [f.write(b'x'*4096) or os.fsync(f.fileno()) for _ in range(20)]"
echo "        print(f'{(time.monotonic()-t0)/20*1000:.1f}ms per fsync')\""
