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

# Kill cockroach server processes using the sim mounts before unmounting.
# Use "cockroach start" to avoid matching parent scripts that have "cockroach"
# in their command-line arguments (e.g. run_tiered_bench.sh ~/cockroach/cockroach).
pkill -f "cockroach start" 2>/dev/null || true
sleep 2
pkill -9 -f "cockroach start" 2>/dev/null || true
for _i in $(seq 1 15); do
  pgrep -f "cockroach start" >/dev/null 2>&1 || break
  sleep 1
done
for node in 1 2 3; do
  fuser -km "/mnt/crdb${node}" 2>/dev/null || true
done
sleep 1

for node in 1 2 3; do
  DEV_NAME="crdb${node}"
  MNT="/mnt/crdb${node}"

  for _try in $(seq 1 5); do
    if ! grep -q "/mnt/crdb${node} " /proc/mounts 2>/dev/null; then
      break
    fi
    umount -f "$MNT" 2>/dev/null || true
    sleep 1
  done
  if ! grep -q "/mnt/crdb${node} " /proc/mounts 2>/dev/null; then
    echo "  node${node}: unmounted $MNT"
  else
    echo "  node${node}: WARNING: $MNT still mounted; trying lazy unmount"
    umount -l "$MNT" 2>/dev/null || true
    sleep 2
  fi

  if dmsetup info "$DEV_NAME" >/dev/null 2>&1; then
    removed=false
    for _try in $(seq 1 15); do
      if dmsetup remove "$DEV_NAME" 2>/dev/null; then
        echo "  node${node}: removed /dev/mapper/$DEV_NAME"
        removed=true
        break
      fi
      sleep 1
    done
    if ! $removed; then
      echo "  node${node}: WARNING: could not remove /dev/mapper/$DEV_NAME; skipping loop detach to avoid a stale dm device"
      continue
    fi
  fi

  # Detach loopback only after dm removal succeeds. Detaching the loop first
  # leaves dm pointing at a dead device, which can require a reboot to clear.
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
