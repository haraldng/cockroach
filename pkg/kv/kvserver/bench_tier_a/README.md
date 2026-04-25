# Raft WAL quorum-sync benchmark (Phase 2, Scenario 1)

Benchmarks for a hypothetical "quorum-of-N Raft WAL sync" feature.
The feature lets N−Q replicas skip local WAL persistence per entry while Q
replicas persist, reducing per-cluster fsync IOPS and write bandwidth.

Two designs are simulated via cluster settings (no real replication changes):

| Design | Setting | What is skipped |
|--------|---------|-----------------|
| D1 — fsync-skip | `kv.raft_log.simulated_quorum_skip_probability` | `fsync` barrier only; entry bytes still reach the WAL |
| D2 — write-skip | `kv.raft_log.simulated_wal_write_skip_probability` | Entire Pebble batch write + fsync; no bytes written |

Both settings take a float in `[0, 1]` (skip probability per entry per
replica). For N=3, Q=2 the theoretical skip probability is `(N−Q)/N = 1/3`.

> **Safety note.** These settings lie to Raft about durability. They are safe
> for steady-state benchmarks but **not safe across restarts**. Under D2 the
> skipped replica has no local copy of the entry; if all replicas skip the same
> entry (probability `p^N`) Raft will panic when it tries to read entries back
> for log truncation. Keep `p ≤ 0.5` for N=3, and do not run D2 at `p=1.0`
> for more than ~60 seconds.

The full per-package documentation for the simulation knobs lives in
[`pkg/kv/kvserver/logstore/RAFT_WAL_SIMULATION.md`](../logstore/RAFT_WAL_SIMULATION.md).

---

## Files in this directory

| File | Purpose |
|------|---------|
| `phase2_scenario1.sh` | 5-scenario benchmark matrix (baseline, s1\_p33, s1\_p100, s2\_p33, s2\_p100) |
| `analyze_vars.py` | Parses `pre_*/post_*.vars` snapshots into latency percentile tables |
| `sim_disk/setup_sim_disks.sh` | Creates dm-delay block devices for per-node stores |
| `sim_disk/teardown_sim_disks.sh` | Unmounts and removes dm-delay devices |
| `sim_disk/run_tiered_bench.sh` | Sweeps four disk tiers; calls setup → phase2 → teardown for each |
| `phase2_scenario1_results/` | Per-run output: `.txt` workload logs, `.vars` metric snapshots |

---

## Quick start — laptop (no disk simulation)

Useful for verifying the scripts work and for a sanity-check baseline.
NVMe fsync (~0.1 ms) is too fast to show the feature's gains; treat results
as "does it run" only, not as a performance signal.

```bash
./dev build cockroach
./pkg/kv/kvserver/bench_tier_a/phase2_scenario1.sh ./cockroach
```

Results are written to `phase2_scenario1_results/`.

---

## Recommended: disk-latency simulation on a cloud Linux VM

The benchmark requires realistic fsync latency (≥1 ms per call) before the
quorum-sync feature shows any throughput gain.  Rather than provisioning
specific disk types, we use the Linux `dm-delay` device-mapper target to inject
configurable write latency on top of a loopback device.  cgroups v2 `io.max`
adds an optional write-bandwidth cap.

This runs on **any** Ubuntu 22.04+ VM — a single `n2-standard-8` (GCP) or
`c5.2xlarge` (AWS) is sufficient.

### Prerequisites

```bash
# Install required tools
sudo apt-get update -q
sudo apt-get install -y dmsetup util-linux e2fsprogs

# Verify cgroups v2 is active (must show a cgroup2 line)
mount | grep cgroup2

# Verify the "io" controller is available
cat /sys/fs/cgroup/cgroup.controllers   # must include "io"

# If "io" is missing:
echo "+io" | sudo tee /sys/fs/cgroup/cgroup.subtree_control
```

### Build and transfer

**Option A — cross-compile on your local machine (faster, recommended)**

```bash
# On your local machine
GOOS=linux GOARCH=amd64 ./dev build cockroach --cross=linux

# Copy binary and scripts to the VM
scp cockroach-linux-2.6.32-gnu-amd64 user@vm-ip:~/cockroach-bin
rsync -av pkg/kv/kvserver/bench_tier_a/ user@vm-ip:~/bench_tier_a/
```

**Option B — build directly on the VM**

Requires ~40 GB of extra disk (Bazel cache + Go toolchain downloads) and
~30–45 minutes on a `c6i.4xlarge`. Use a **200 GB** root volume instead of
150 GB if building on the VM.

```bash
# On the VM — install build dependencies
sudo apt-get install -y git cmake ninja-build

# Install Bazel via Bazelisk (the ./dev tool requires it)
sudo curl -Lo /usr/local/bin/bazel \
  https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
sudo chmod +x /usr/local/bin/bazel

# Clone the repo (shallow clone saves ~8 GB of git history)
git clone --depth=1 https://github.com/cockroachdb/cockroach.git
cd cockroach

# Build (first run downloads toolchains and populates the Bazel cache)
./dev build short   # ~30–45 min; produces ./cockroach

# Copy bench scripts and binary to a working directory.
# Keep the binary name distinct from the source checkout directory (`~/cockroach`).
cp -r pkg/kv/kvserver/bench_tier_a ~/bench_tier_a
cp cockroach ~/bench_tier_a/cockroach
```

If the source checkout already lives at `~/cockroach`, do **not** copy the
binary to `~/cockroach`; that path is a directory. Use `~/bench_tier_a/cockroach`
or another explicit binary filename such as `~/cockroach-bin`.

### Disk space and loopback image size

Each simulated node gets a loopback image file under `$IMG_DIR` (default
`/tmp/crdb-sim`).  The default size is **10 GB per node**.  For a full tier
run (5 scenarios × ~7 min on a live cluster) each node can accumulate 10–15 GB
of WAL and SST data, so the default is tight.  Set `IMG_SIZE_MB` before
running:

```bash
export IMG_SIZE_MB=20480   # 20 GB per node → 60 GB total across 3 nodes
```

Total VM disk recommendation: **150 GB** (covers OS, source checkout, Bazel
cache, binary, and the 60 GB of loopback images with headroom).  If you
cross-compile the binary on your local machine and `scp` it instead of
building on the VM, 100 GB is sufficient.

### Run all four disk tiers (~2 hours)

```bash
ssh user@vm-ip
cd ~/bench_tier_a
export IMG_SIZE_MB=20480
sudo --preserve-env=IMG_SIZE_MB ./sim_disk/run_tiered_bench.sh ~/bench_tier_a/cockroach
```

This sweeps four tiers in sequence:

| Tier | dm-delay write | cgroups wbps | Represents |
|------|---------------|--------------|------------|
| `nvme` | 0 ms | uncapped | Local NVMe — control, no expected feature win |
| `ssd-fast` | 1 ms | 400 MB/s | GCP pd-ssd / AWS gp3 |
| `ssd-slow` | 3 ms | 240 MB/s | GCP pd-balanced / AWS gp2 |
| `hdd` | 8 ms | 100 MB/s | GCP pd-standard / spinning |

Results land in a timestamped directory:
`phase2_scenario1_results/run-YYYYmmdd-HHMMSS/{nvme,ssd-fast,ssd-slow,hdd}/`.
Set `RESULTS_ROOT` if you want a specific output directory.

### Retrieve results

```bash
# From your local machine
rsync -av user@vm-ip:~/bench_tier_a/phase2_scenario1_results/ \
  pkg/kv/kvserver/bench_tier_a/phase2_scenario1_results/
```

### Run a single tier manually

```bash
# Set up 3ms write-delay devices (ssd-slow tier)
sudo ./sim_disk/setup_sim_disks.sh 3 240

# Verify the simulation is in the I/O path
python3 -c "
import time, os
f = open('/mnt/crdb1/probe', 'wb')
t0 = time.monotonic()
for _ in range(20):
    f.write(b'x' * 4096)
    os.fsync(f.fileno())
print(f'{(time.monotonic()-t0)/20*1000:.1f}ms per fsync')
"
# Expected: ~3.0ms  (if you see ~0.0ms the dm device is not in the path)

# Point nodes at their separate disks and run
export NODE_STORE_1=/mnt/crdb1
export NODE_STORE_2=/mnt/crdb2
export NODE_STORE_3=/mnt/crdb3
export IMG_DIR=/tmp/crdb-sim
./phase2_scenario1.sh ~/bench_tier_a/cockroach

# Tear down when done
sudo ./sim_disk/teardown_sim_disks.sh
```

---

## Scenarios in the matrix

| Scenario | Setting | Description |
|----------|---------|-------------|
| `baseline` | — | Stock cluster; the "before" |
| `s1_p33` | `simulated_quorum_skip_probability = 0.333` | D1 at N=3, Q=2: fsync-skip only |
| `s1_p100` | `simulated_quorum_skip_probability = 1.0` | D1 ceiling: every entry skips fsync |
| `s2_p33` | `simulated_wal_write_skip_probability = 0.333` | D2 at N=3, Q=2: full write-skip |
| `s2_p100` | `disable_synchronization_unsafe = true` | Runtime-stable ceiling on fsync cost |

`s2_p100` uses `disable_synchronization_unsafe` (not `p=1.0` write-skip)
because D2 at `p=1.0` crashes all nodes after ~60 s when Raft tries to read
entries for log truncation and finds nothing on disk.

---

## Interpreting results

Use `s2_p100` (no-fsync everywhere) as the runtime-stable ceiling:

```
feature_captured = (featureSim - baseline) / (ceiling - baseline)
```

Key formulas (apply per-tier, using `avgCommit(ms)` from the summary table):

```
D1 capture fraction  = (s1_p33 - baseline) / (s1_p100 - baseline)
D2 capture fraction  = (s2_p33 - baseline) / (s2_p100 - baseline)
write-BW share of D2 = (s2_p33 - s1_p33)  / (s2_p100 - baseline)
S1 ceiling check     : s1_p100 ≈ s2_p100   (both disable fsyncs, different knobs)
```

Expected pattern across tiers:
- **nvme**: all captures ≈ 0 (fsync too cheap — confirms laptop is invalid)
- **ssd-fast**: D1 capture rises; D2 capture higher when WAL bandwidth binds
- **ssd-slow / hdd**: both captures grow; `write-BW share` distinguishes D1 vs D2 value

For latency percentiles (p50/p95/p99) from Prometheus histogram deltas:

```bash
python3 bench_tier_a/analyze_vars.py

# Or with all three nodes captured (re-run with ALL_NODES=true first):
ALL_NODES=true ./phase2_scenario1.sh <binary>
python3 bench_tier_a/analyze_vars.py --nodes 3
```

---

## Porting to another codebase

The simulation requires three things:

1. **A cluster setting** (`float64`, `WithUnsafe`) controlling skip probability.
2. **A coin flip** at the single choke-point where entries are appended to
   stable storage (equivalent to `storeEntriesAndCommitBatch` in
   `pkg/kv/kvserver/logstore/logstore.go`).
3. **Invariants to preserve on skip:**
   - HardState is always persisted.
   - In-memory Raft state (`LastIndex`, `LastTerm`) always advances.
   - The `OnLogSync` / durability callback always fires.
   - Overwriting appends are never skipped.

The Go implementation lives in
`pkg/kv/kvserver/logstore/logstore.go` (`storeEntriesAndCommitBatch`).
The unit test is `TestSimulatedWALWriteSkip` in `logstore_test.go`.
