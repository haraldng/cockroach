# Quorum-rotating Raft WAL sync — feature design and simulation

This document describes the "quorum-rotating Raft WAL sync" feature, the two
design variants under evaluation, how the simulation is implemented in
CockroachDB, and how to reproduce the benchmarks. It is written to be
self-contained so that a reader with no prior context — including an agent
working in a different codebase — can understand the idea and adapt it.

---

## The problem

In a standard Raft group with N replicas and quorum Q = ⌊N/2⌋ + 1, every log
entry is persisted (written and fsynced) by all N replicas before the leader
acknowledges a commit. For N=3, Q=2, one replica's disk work is entirely
redundant for safety: the commit is already durable as soon as any two replicas
have persisted the entry.

On write-heavy workloads this per-entry fsync (and, on bandwidth-limited
hardware, the WAL write itself) is the dominant latency contributor. The wasted
disk work on the third replica is the target.

---

## The feature idea

Reduce the per-entry disk work on N−Q replicas per round, rotating which
replicas do the full persist so that the load reduction is spread evenly over
time. Each entry is persisted by exactly Q replicas (a rotating "persisting
subset"); the remaining N−Q replicas are "non-persisting" for that entry and do
less or no local disk work.

The non-persisting replica still acks durability to the Raft leader, which is
**correct at runtime** as long as at least Q replicas actually did persist the
entry. It is **not safe across restarts** without an additional recovery step:
the non-persisting replica must be able to refetch any un-persisted entries from
a peer before it can safely participate in leader election or log reads.

For N=3, Q=2, the non-persisting probability per replica is (N−Q)/N = 1/3. On
average each replica skips 1 in 3 entries.

---

## Two design variants

The feature has two meaningfully different implementations, with different
cost/benefit profiles on different hardware bottlenecks.

### Design (1) — fsync skip only

The non-persisting replica **writes** the entry bytes to its local WAL (they
reach the OS page cache), but skips the `fsync`/`fdatasync` barrier.

- Saves: fsync latency and IOPS. On network-attached cloud SSDs (1–5 ms fsync),
  this is the dominant disk cost.
- Does not save: write bandwidth. Bytes still flow to disk via dirty-page
  writeback. On a bandwidth-saturated disk, this design's win is near zero.
- Safe to read back: entries are in the OS page cache and in the storage engine;
  any subsequent read succeeds. No crash risk from Raft reading its own log.

### Design (2) — WAL write skip

The non-persisting replica **does not write the entry to its WAL at all**. The
Pebble batch commit for that entry is skipped entirely. HardState (Raft
metadata: term, vote, commit index) is still persisted on every append.

- Saves: fsync latency, IOPS, **and** WAL write bandwidth. Per-replica WAL
  bytes drop by approximately the skip probability.
- Safety hazard: the entry does not exist on disk. If Raft later tries to read
  that entry (for replication to a lagging follower, log truncation, or
  snapshotting), it returns `ErrUnavailable`, which causes the Raft
  implementation to panic. This makes Design (2) **unstable in a real cluster**
  at high skip probabilities or over long runs. At p=1/3 with N=3, each entry
  has a (1/3)^3 ≈ 3.7% chance of being skipped by every replica; a real
  cluster will eventually try to read one of those entries and crash.
- A production implementation of Design (2) must solve re-entry acquisition:
  before a non-persisting replica can serve reads or become leader, it must
  refetch all skipped entries from a peer. The simulation does not model this.

---

## How the simulation is implemented

Rather than modifying the Raft protocol, the simulation adds probabilistic knobs
to the log storage layer. Each replica independently rolls a die on each append
and either performs the full write or pretends to (advancing in-memory state,
firing the durability callback, but skipping some or all of the disk work).

### Code location (CockroachDB)

All simulation logic lives in a single function:

```
pkg/kv/kvserver/logstore/logstore.go
  storeEntriesAndCommitBatch()
```

The function is the single code path that writes Raft log entries and commits
them to the storage engine. The simulation intercepts it in two places:

**1. Entry-write skip (Design 2)** — decided at the top of the entry-write
block, before `MaybeSideloadEntries` and `logAppend`:

```go
willSkipWrite := false
if len(m.Entries) > 0 {
    overwriting := firstPurge <= prevLastIndex
    if !overwriting {
        if p := SimulatedWALWriteSkipProbability.Get(&s.Settings.SV); p > 0 && rand.Float64() < p {
            willSkipWrite = true
        }
    }
    if willSkipWrite {
        // Advance in-memory state as if entries were written, skip disk.
        last := &m.Entries[len(m.Entries)-1]
        state.LastIndex = kvpb.RaftIndex(last.Index)
        state.LastTerm  = kvpb.RaftTerm(last.Term)
    } else {
        // Normal path: sideload extraction + Pebble batch append.
        thinEntries, entryStats, err := MaybeSideloadEntries(...)
        state, err = logAppend(ctx, s.StateLoader.RaftLogPrefix(), batch, state, thinEntries)
    }
}
```

**2. Fsync skip (Design 1)** — decided after the batch is built, just before
`batch.Commit`:

```go
willSync := wantsSync && !DisableSyncRaftLog.Get(&s.Settings.SV)
if willSkipWrite {
    willSync = false   // Design 2 already skips everything
}
if willSync && !overwriting && !willSkipWrite {
    if p := SimulatedQuorumSkipProbability.Get(&s.Settings.SV); p > 0 && rand.Float64() < p {
        willSync = false
    }
}
```

`wantsSync` is left `true` in both cases so the `OnLogSync` callback still
fires, delivering the Raft ack as if the entry were durable.

### Invariants preserved by the simulation

| Invariant | Reason |
|-----------|--------|
| `OnLogSync` callback always fires when `wantsSync` | Raft ack must be delivered regardless of local disk choice |
| HardState always persisted | Term, vote, and commit index must be durable for Raft correctness |
| Overwriting appends never skipped | The overwriting path may purge sideloaded SST files; it must sync before that |
| In-memory `RaftState.LastIndex` / `LastTerm` always advances | Raft reads these fields in-memory to determine what to send to followers |
| `ByteSize` intentionally **not** updated on Design-2 skip | Simulation; undercounting on-disk size is acceptable |

### Cluster settings

```
kv.raft_log.synchronization.unsafe.disabled       bool    Design-1 ceiling: no fsyncs, cluster-wide
kv.raft_log.simulated_quorum_skip_probability     float   Design-1 simulation: per-entry fsync-skip probability
kv.raft_log.simulated_wal_write_skip_probability  float   Design-2 simulation: per-entry write-skip probability
```

All three are registered as `settings.WithUnsafe` and are cluster-system-only.
The UNSAFE token must be presented to set them via SQL.

### Micro-benchmark knob (raftstorebench)

The micro-benchmark in `pkg/kv/kvserver/raftstorebench/` bypasses the full
Raft machinery and directly benchmarks the storage layer. It exposes the
Design (2) simulation via a config field:

```go
// Config.RaftSkipWriteProbability: when p > 0, the raft WAL batch is
// discarded (not committed) with probability p per write.
RaftSkipWriteProbability float64
```

Implemented in `worker.go`:

```go
if p := w.o.cfg.RaftSkipWriteProbability; p > 0 && w.rng.Float64() < p {
    batches.raftBatch.Close()   // discard without committing
} else if err = batches.raftBatch.Commit(!w.o.cfg.RaftNoSync); err != nil {
    return err
}
```

In-memory replica state (`nextRaftLogIndex`, `logSizeBytes`) advances in
`generateBatches`, which is called before the commit decision, so the rest of
the benchmark sees consistent replica state regardless of whether the batch was
written.

---

## Correctness test

`pkg/kv/kvserver/logstore/logstore_test.go` contains `TestSimulatedWALWriteSkip`
which verifies the three critical properties of the Design-2 path:

1. **skip=1.0 drops all non-overwriting writes**: after N appends with skip
   probability 1.0, no entry bytes appear in the storage engine
   (`storage.ComputeStats` returns 0 for the Raft log key range), but
   `RaftState.LastIndex` advanced correctly and `OnLogSync` fired N times.

2. **skip=0.0 writes normally**: entries appear on disk when the knob is off.

3. **Overwriting appends are never skipped**: even at skip=1.0, an overwrite
   (new entry at an already-written index) must persist so that sideloaded
   files can be purged safely.

---

## Benchmark methodology

### Tier A — in-process microbenchmark (fast, weak signal)

`BenchmarkReplicaProposal` in `pkg/kv/kvserver` exercises the single-node
proposal path with an in-process follower. It is fast but does not stress
the WAL because the in-process disk is NVMe-speed and the test is
single-threaded by default.

**Finding**: on an Apple M1 Pro laptop, disabling fsync entirely shows no
statistically significant improvement (p≈0.11 at n=10). This bench is not a
useful signal for WAL-related features on modern NVMe hardware.

### Tier B — multi-node workload benchmark (end-to-end signal)

`pkg/kv/kvserver/bench_tier_a/phase2_scenario1.sh` runs a 3-node local cluster
and measures `workload kv` throughput under five settings:

| Label | Setting | What it isolates |
|-------|---------|-----------------|
| `baseline` | none | reference |
| `s1_p33` | `simulated_quorum_skip_probability = 0.333` | Design-1 at quorum margin |
| `s1_p100` | `simulated_quorum_skip_probability = 1.0` | Design-1 ceiling (per-entry knob) |
| `s2_p33` | `simulated_wal_write_skip_probability = 0.333` | Design-2 at quorum margin |
| `s2_p100` | `disable_synchronization_unsafe = true` | Design-1/2 ceiling (global knob) |

Key formulas:

```
design-1 capture fraction = (s1_p33 − baseline) / (s1_p100 − baseline)
design-2 capture fraction = (s2_p33 − baseline) / (s2_p100 − baseline)
write-bandwidth share     = (s2_p33 − s1_p33)  / (s2_p100 − baseline)
```

The last formula isolates how much of Design-2's win comes from avoiding the
WAL write (vs. just the fsync). If this fraction is high, Design-2 is needed;
if it is near zero, Design-1 is sufficient.

**Finding on a local laptop**: results are inconclusive and contradictory across
runs. The laptop NVMe has ~0.1ms fsync latency; all three nodes share the same
disk. This is insufficient hardware for a WAL-cost feature. See the disk
selection section below.

### Disk selection for meaningful results

The feature's gains are proportional to per-fsync latency. Use
**network-attached SSD** (not local NVMe / instance store):

| Platform | Recommended | Avoid |
|----------|-------------|-------|
| GCP | `pd-ssd`, 500 GB, `n2-standard-8` | local SSD (`--local-ssd`), `pd-extreme` |
| AWS | `gp3`, 500 GB, 6000 IOPS, `m6i.2xlarge` | instance store, `gp2` (burst credits) |

Before a full run, verify the bottleneck is disk by checking
`storage.wal.fsync-latency` p50 during baseline. If p50 < 0.5 ms, the
workload is CPU- or network-bound on this hardware, not disk-bound, and the
feature will show no gain regardless of design.

---

## Known safety limits

| Scenario | Design-1 | Design-2 |
|----------|----------|----------|
| Leader reads its own log for follower catch-up | Safe (entry is on disk) | **Crash** if entry was skipped — `ErrUnavailable` → panic in `raft/log.go` |
| Raft log truncation / snapshot creation | Safe | **Crash** (same mechanism) |
| Node restart | Unsafe (skipped fsyncs may not have reached disk) | **Crash** (entry not on disk at all) |
| Short benchmark run (< truncation interval) | Safe enough | Safe enough at p ≤ 0.333 |

The truncation interval is approximately the time to write ~16 MiB of Raft log
per range. On a busy cluster this can be well under a minute.

---

## How to adapt this to another Raft system

The simulation pattern is general. The key steps, system-agnostic:

**1. Find the single code path that commits a Raft log entry to stable storage.**
In most systems there is one function (here: `storeEntriesAndCommitBatch`) that
prepares a write batch and calls something like `batch.Commit(sync=true)`. That
is the only place that needs to change.

**2. Add two probabilistic knobs** (cluster/node-level runtime settings):
- `design1_skip_prob` (float, 0–1): after writing the batch, flip a coin; if
  heads, call `batch.Commit(sync=false)` instead of `batch.Commit(sync=true)`.
- `design2_skip_prob` (float, 0–1): before building the batch, flip a coin; if
  heads, skip the batch entirely (do not write entry bytes, do not commit).

**3. Preserve these invariants regardless of the coin flip:**
- Advance the in-memory log state (LastIndex, LastTerm) as if the write happened.
- Fire the durability callback / ack durability back to Raft.
- Always persist HardState (term, vote, commit — the Raft metadata record).
- Never skip an overwriting append (one that truncates a log suffix).

**4. Gate both knobs to non-overwriting appends** where the sync would have
happened. Overwriting appends must sync before sideloaded/auxiliary files can
be removed.

**5. Write a correctness test** that verifies:
- At skip-prob=1.0, no entry bytes appear in the storage engine but the
  in-memory index advanced and the ack callback fired.
- At skip-prob=0.0, entries appear on disk normally.
- Overwriting appends are never skipped even at skip-prob=1.0.

**6. Document the stability limits** (see the table above) so benchmark users
know which skip probabilities are safe for which run durations.
