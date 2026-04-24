# Raft WAL quorum-sync simulation

This package exposes three cluster settings for benchmarking a hypothetical
"quorum-of-N Raft WAL sync" feature without implementing it. All are unsafe;
use them only on a throwaway cluster that is expected to be wiped after the
run.

- `kv.raft_log.synchronization.unsafe.disabled` (a.k.a.
  `kv.raft_log.disable_synchronization_unsafe`) — if `true`, this replica never
  fsyncs Raft log appends (it still writes to the WAL but skips flush and
  fsync). Sibling of the flags below.
- `kv.raft_log.simulated_quorum_skip_probability` — design (1): a float in
  `[0, 1]`. If `p > 0`, this replica flips a coin per non-overwriting append
  and skips the **fsync** with probability `p`, while still writing the entry
  bytes to the WAL and acking the append to Raft as durable. Models a feature
  that drops per-replica fsync cost but leaves WAL bytes unchanged.
- `kv.raft_log.simulated_wal_write_skip_probability` — design (2): same per-entry
  coin flip, but on skip the replica **does not write the entry to its WAL at
  all** (and also does not fsync). Advances the in-memory Raft state and acks
  durability to Raft. HardState is still persisted on every append. Models a
  feature where non-persisting replicas do zero entry work locally; this is
  the regime where per-replica WAL bandwidth drops by the skip probability.

In all cases the replica is lying to Raft about durability, which is
**runtime-correct** as long as at least a quorum of replicas really did
persist the entry, but is **not safe across restarts**. Under design (2) the
skipped replica has no local copy of the entry at all, so a real
implementation would need peer refetch on restart; the simulation omits this
and only supports benchmarking steady-state throughput/latency.

`kv.raft_log.simulated_quorum_skip_probability` and
`kv.raft_log.simulated_wal_write_skip_probability` are checked in order on
each append; design (2) wins if both fire on the same entry.

## Benchmark configurations

Run the same workload against each of these, on the same hardware, and compare
throughput, per-replica WAL fsync counts, and cluster-level p50/p99/p99.9
commit latency.

### Baseline

Stock cluster, no settings changed. This is the "before."

### U — upper bound (no-fsync everywhere)

Models "Raft WAL **sync** cost is zero everywhere": every replica still writes
entry bytes to its WAL, but skips flush and fsync on every append.

This is the **runtime-stable** ceiling on fsync cost for any Raft-WAL feature.
If the gap from baseline to U is small on a workload, a quorum-sync feature
cannot save more than that gap in fsync work on this workload — and the workload
is not a good IOPS demo.

```sql
SET CLUSTER SETTING kv.raft_log.synchronization.unsafe.disabled = true;
```

Applies cluster-wide. Revert with `RESET` (or set to `false`).

**Why not S2 with p = 1.0?** Setting `simulated_wal_write_skip_probability = 1.0`
skips the entire entry write on every replica, so no replica ever persists any
Raft log entry. After a few minutes Raft attempts log truncation, which requires
reading entries back for snapshotting — and panics when it finds nothing on disk.
This crashes all nodes mid-run, making it unsuitable as a benchmark ceiling.
`p = 1.0` is only safe for runs shorter than the Raft log truncation interval
(roughly the time to write ~16 MiB of Raft log per range). Stick to `p` values
where the probability that **no** replica persists a given entry remains negligible
in practice, e.g. `p ≤ 0.5` for `N=3`.

### U_write — write+fsync skip upper bound (theoretical, not runnable long-term)

For reference: `simulated_wal_write_skip_probability = 1.0` models the ceiling
on **both** WAL bytes and fsync cost. It is the maximum possible saving, but as
noted above it destabilises the cluster after a few minutes. It can be used for
very short micro-benchmarks (< 60s) where Raft log truncation has not yet
triggered. Do not use for sustained workload benchmarks.

### S0 — static subset (one replica never syncs)

Models "one specific replica is always in the skipped subset." On an `N=3`
cluster, setting this on exactly one node makes every entry durable on the
other two, which matches quorum `Q=2`.

SQL-only form (applies cluster-wide, not per-node):

```sql
-- does NOT work for S0; cluster-wide SQL turns sync off on every node (U_sync).
```

S0 requires per-node control, which the SQL setting does not provide. Use the
env var on exactly one node at startup:

```bash
# On node 1 only:
COCKROACH_DISABLE_RAFT_LOG_SYNCHRONIZATION_UNSAFE=true cockroach start ...
# On nodes 2 and 3: start normally (env var unset or false).
```

This is coarse — the "lucky" replica avoids 100% of syncs rather than
`(N-Q)/N`, so it over-counts the per-replica work reduction — but it's the
zero-code way to get a first data point.

### S1 — design (1): probabilistic per-entry sync skip

Each replica independently skips the **fsync** per-entry with probability `p`;
bytes still reach the WAL and drift to disk via dirty-page writeback. Matches
a feature that reduces fsync cost but not WAL bandwidth. Good for modeling
IOPS-bound workloads; under-counts the win on throughput-bound workloads
(the bytes still flow).

For `N=3, Q=2`, set `p = 1/3`:

```sql
SET CLUSTER SETTING kv.raft_log.simulated_quorum_skip_probability = 0.333;
```

Applies cluster-wide and can be flipped at runtime. Reset with:

```sql
RESET CLUSTER SETTING kv.raft_log.simulated_quorum_skip_probability;
```

### S2 — design (2): probabilistic per-entry WAL-write skip

Each replica independently skips the **entire entry write** (Pebble batch
append + sideload extraction + fsync) per-entry with probability `p`.
HardState is still persisted. Advances in-memory Raft state and acks
durability to Raft. This is the closest available simulation of a
quorum-sync feature where non-persisting replicas do zero entry work
locally — the regime where per-replica WAL bandwidth scales with `1-p`.

At `p = 1.0` every append is skipped on every replica (see **U_write** above), but this is unstable for long runs; see that section for why.

For `N=3, Q=2`, set `p = 1/3`:

```sql
SET CLUSTER SETTING kv.raft_log.simulated_wal_write_skip_probability = 0.333;
```

S2 is strictly stronger than S1 on the skipped entries: it removes both WAL
bytes and the fsync barrier. When comparing the two on a bandwidth-bound
workload (e.g. `kv0/size=64kb`), S2's per-node `storage.wal.bytes_written`
should drop by roughly `p`; S1's should not drop at all.

### Notes common to S1 and S2

- Each replica decides independently, so with `p=1/3, N=3` there is a
  `1/27 ≈ 3.7%` chance no replica persists a given entry. Still
  runtime-correct; restart is unsafe (and under S2 the skipped replica has
  no local copy to recover from even if another replica did sync).
- Overwriting appends are never skipped (the overwriting path must sync
  before sideloaded files can be purged). Overwriting is rare; this does not
  materially bias the result.
- Use `p` values strictly less than `(N-Q)/N` if you want the quorum
  invariant to hold in expectation with margin.
- S1 and S2 are evaluated in order per append; S2 wins if both fire on the
  same entry. To get the "pure S1" behavior, leave the S2 setting at 0.

## Interpretation

Report all numbers side-by-side for each workload. Use **U** (no-fsync everywhere,
`disable_synchronization_unsafe = true`) as the runtime-stable ceiling on fsync cost:

```
feature_captured_fraction = (featureSim - baseline) / (U - baseline)
```

where `featureSim` is e.g. S2 at `p = (N-Q)/N` (e.g. `p = 1/3` for `N=3`, `Q=2`).

e.g. "S2 with p=0.33 captures 70% of the theoretical max (U − baseline) on
`kv0/nodes=3/cpu=32/size=64kb`" is a much more defensible claim than a raw
"+12% throughput."

If you only care about **fsync** cost (not WAL bytes), compare against
`U_sync` instead of U — but do not mix U and `U_sync` in the same denominator
without saying which ceiling you mean.

On bandwidth-bound workloads, also compare S1 and S2 directly — the S2 - S1
gap is the portion of the feature's win attributable to avoiding the entry
write, not just the fsync barrier.

## Metrics to scrape

- Per-node (important — aggregates hide Win A):
  - `storage.wal.fsync-latency` p50/p99/p99.9
  - `storage.wal.bytes`
  - Count of WAL fsyncs per second
  - `raft.process.logcommit.latency`
  - `raft.commandcommit.latency`
- Cluster-level:
  - Workload throughput
  - p50/p99/p99.9 commit latency
  - Admission: `admission.wait_durations.kv`

## Companion plan

The full benchmarking strategy (workload tiers, heterogeneous-disk scenarios
for Win B, and a first-two-weeks shortlist) lives outside this package in the
approved Raft WAL benchmark plan.
