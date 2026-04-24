#!/usr/bin/env bash
# Unmounts and removes dm-delay simulation disks created by setup_sim_disks.sh.
#
# Usage: sudo ./teardown_sim_disks.sh
#
# Image files at $IMG_DIR are kept so the next setup_sim_disks.sh run can skip
# re-allocation (fallocate). Delete them manually to reclaim disk space:
#   rm -rf "${IMG_DIR:-/tmp/crdb-sim}"

set -euo pipefail

IMG_DIR="${IMG_DIR:-/tmp/crdb-sim}"

# Kill any cockroach processes using the sim mounts before unmounting.
pkill -f "cockroach start" 2>/dev/null || true
sleep 2

for node in 1 2 3; do
  DEV_NAME="crdb${node}"
  MNT="/mnt/crdb${node}"

  umount "$MNT" 2>/dev/null && echo "  node${node}: unmounted $MNT" || true

  if dmsetup info "$DEV_NAME" >/dev/null 2>&1; then
    dmsetup remove "$DEV_NAME" && echo "  node${node}: removed /dev/mapper/$DEV_NAME" || true
  fi

  # Detach loopback device if we recorded its path, otherwise scan by image file.
  LOOP_FILE="$IMG_DIR/node${node}.loop"
  if [[ -f "$LOOP_FILE" ]]; then
    LOOP=$(cat "$LOOP_FILE")
    losetup -d "$LOOP" 2>/dev/null && echo "  node${node}: detached $LOOP" || true
    rm -f "$LOOP_FILE"
  else
    # Fallback: detach any loops backed by our image file.
    losetup -j "$IMG_DIR/node${node}.img" 2>/dev/null \
      | cut -d: -f1 | xargs -r losetup -d || true
  fi

  # Remove cgroup if it was created.
  CGROUP="/sys/fs/cgroup/crdb${node}"
  if [[ -d "$CGROUP" ]]; then
    # Move any lingering processes out before rmdir.
    cat "$CGROUP/cgroup.procs" 2>/dev/null | while read -r pid; do
      echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
    done
    rmdir "$CGROUP" 2>/dev/null || true
    echo "  node${node}: removed cgroup $CGROUP"
  fi
  rm -f "$IMG_DIR/node${node}.cgroup"
done

echo ""
echo "==> Sim disks torn down."
echo "    Image files kept at $IMG_DIR — delete manually to reclaim space."
