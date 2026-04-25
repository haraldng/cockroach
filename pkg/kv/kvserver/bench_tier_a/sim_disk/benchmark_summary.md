# Bench tier A — results summary

This file snapshots the results shown in the canvas (`raft-wal-benchmark-analysis.canvas.tsx`)
into a plain markdown artifact.

Source data directory: `~/bench_tier_a/phase2_scenario1_results/{nvme,ssd-fast,ssd-slow,hdd}/`

## Definitions

All “relative improvement” numbers are computed against the tier’s `baseline`:

- **throughput**: \((\mathrm{ops/sec}_{scenario} - \mathrm{ops/sec}_{baseline}) / \mathrm{ops/sec}_{baseline}\)
- **avg latency**: \((\mathrm{avg}_{baseline} - \mathrm{avg}_{scenario}) / \mathrm{avg}_{baseline}\)
- **p50 latency**: \((\mathrm{p50}_{baseline} - \mathrm{p50}_{scenario}) / \mathrm{p50}_{baseline}\)

Positive latency numbers mean latency **decreased** (improved).

## Relative improvements (baseline → scenario)

| tier | scenario | throughput | avg latency | p50 latency |
|---|---|---:|---:|---:|
| nvme | s1_p33 | +8.2% | +7.9% | +15.4% |
| nvme | s1_p100 | +1.6% | +2.1% | +15.4% |
| nvme | s2_p33 | -2.3% | -2.1% | +11.0% |
| nvme | s2_p100 | -15.6% | -17.9% | +7.4% |
| ssd-fast | s1_p33 | +13.1% | +11.3% | +17.7% |
| ssd-fast | s1_p100 | +8.9% | +7.9% | +17.7% |
| ssd-fast | s2_p33 | +6.5% | +6.0% | +14.3% |
| ssd-fast | s2_p100 | -4.1% | -4.6% | +14.3% |
| ssd-slow | s1_p33 | +32.1% | +24.2% | +28.0% |
| ssd-slow | s1_p100 | +37.0% | +26.8% | +33.3% |
| ssd-slow | s2_p33 | +19.4% | +16.3% | +30.7% |
| ssd-slow | s2_p100 | +10.1% | +9.5% | +30.7% |
| hdd | s1_p33 | +170.1% | +63.1% | +63.9% |
| hdd | s1_p100 | +176.1% | +63.8% | +63.9% |
| hdd | s2_p33 | +160.7% | +61.6% | +61.0% |
| hdd | s2_p100 | +161.8% | +61.9% | +63.9% |

## Raw workload outputs (ops/sec and latencies)

For the raw per-scenario workload output logs, see:

- `~/bench_tier_a/phase2_scenario1_results/nvme/{baseline,s1_p33,s1_p100,s2_p33,s2_p100}.txt`
- `~/bench_tier_a/phase2_scenario1_results/ssd-fast/{baseline,s1_p33,s1_p100,s2_p33,s2_p100}.txt`
- `~/bench_tier_a/phase2_scenario1_results/ssd-slow/{baseline,s1_p33,s1_p100,s2_p33,s2_p100}.txt`
- `~/bench_tier_a/phase2_scenario1_results/hdd/{baseline,s1_p33,s1_p100,s2_p33,s2_p100}.txt`

