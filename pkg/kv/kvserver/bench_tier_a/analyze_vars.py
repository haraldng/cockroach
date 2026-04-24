#!/usr/bin/env python3
"""
analyze_vars.py — Per-Raft metrics analyzer for phase2_scenario1 benchmark.

Reads pre_<scenario>[_n<N>].vars / post_<scenario>[_n<N>].vars files captured
by phase2_scenario1.sh, computes per-run deltas, and emits two tables:

  1. Raft-log commit latency percentiles  (p50 / p95 / p99 / avg, in ms)
     from raft_process_logcommit_latency histogram deltas.
  2. Scalar summary  (WAL bytes, Pebble fsyncs, Raft commits, WAL bytes/op)

When multiple per-node files exist (_n1 _n2 _n3) the script sums them before
computing percentiles, giving cluster-wide rather than single-node numbers.

Usage:
    python3 analyze_vars.py [--results-dir DIR] [--scenarios SC,SC,...] [--nodes N]

    --results-dir   path to results folder  (default: ./phase2_scenario1_results)
    --scenarios     comma-separated scenario names
                    (default: baseline,s1_p33,s1_p100,s2_p33,s2_p100)
    --nodes         number of nodes that were captured (1 or 3)
                    If >1, looks for _n1/_n2/_n3 suffix variants; falls back to
                    un-suffixed file when node files are missing.
"""

import argparse
import math
import os
import re
import sys
from collections import defaultdict


# ---------------------------------------------------------------------------
# Prometheus text-format parser
# ---------------------------------------------------------------------------

_BUCKET_RE = re.compile(
    r'^(\w+)_bucket\{.*?le="([^"]+)".*?\}\s+([\d.e+\-]+)'
)
_SCALAR_RE = re.compile(
    r'^(\w+)\{.*?\}\s+([\d.e+\-]+)'
)


def parse_vars_file(path: str) -> dict:
    """Return {metric_name: value_or_buckets} from a Prometheus text file.

    For histograms the value is a list of (le_float, cumulative_count) pairs
    sorted by le (including +Inf).  For scalars it is a float.
    Merges multiple label combinations (e.g. multiple stores) by summing.
    """
    if not os.path.exists(path):
        return {}

    # Two passes: collect bucket lists and scalars separately.
    buckets: dict[str, dict[float, float]] = defaultdict(dict)
    scalars: dict[str, float] = defaultdict(float)
    hist_names: set[str] = set()

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                # Detect histogram type declarations to avoid treating _sum/_count
                # as plain scalars later.
                if line.startswith('# TYPE') and 'histogram' in line:
                    parts = line.split()
                    if len(parts) >= 3:
                        hist_names.add(parts[2])
                continue

            m = _BUCKET_RE.match(line)
            if m:
                name, le_s, val_s = m.groups()
                le = math.inf if le_s == '+Inf' else float(le_s)
                buckets[name][le] = buckets[name].get(le, 0) + float(val_s)
                hist_names.add(name)
                continue

            m = _SCALAR_RE.match(line)
            if m:
                name, val_s = m.groups()
                # Strip _sum / _count suffixes — we handle them below.
                scalars[name] = scalars.get(name, 0) + float(val_s)

    result: dict = {}

    # Turn bucket dicts into sorted lists.
    for name, bdict in buckets.items():
        result[name] = sorted(bdict.items())  # [(le, cum_count), ...]

    # Scalars: skip _bucket lines already handled above; keep _sum and _count
    # associated with histogram names.
    for name, val in scalars.items():
        result[name] = val

    return result


def merge_vars(files: list[str]) -> dict:
    """Sum metrics across multiple per-node files."""
    merged: dict[str, object] = {}
    for path in files:
        data = parse_vars_file(path)
        for key, val in data.items():
            if key not in merged:
                merged[key] = val
            elif isinstance(val, list):
                # Sum bucket counts element-wise (assume same le boundaries).
                base = merged[key]
                merged[key] = [(le, bc + vc) for (le, bc), (_, vc) in zip(base, val)]
            else:
                merged[key] = merged[key] + val
    return merged


# ---------------------------------------------------------------------------
# Histogram quantile (Prometheus-style)
# ---------------------------------------------------------------------------

def histogram_quantile(q: float, buckets: list) -> float:
    """Standard Prometheus linear interpolation within a bucket."""
    if not buckets:
        return float('nan')
    total = next((c for le, c in reversed(buckets) if le == math.inf), buckets[-1][1])
    if total == 0:
        return 0.0
    target = q * total
    prev_le, prev_c = 0.0, 0.0
    for le, c in buckets:
        if le == math.inf:
            return prev_le
        if c >= target:
            if c == prev_c:
                return prev_le
            frac = (target - prev_c) / (c - prev_c)
            return prev_le + frac * (le - prev_le)
        prev_le, prev_c = le, c
    return float('inf')


def delta_buckets(pre: list, post: list) -> list:
    """Subtract pre cumulative counts from post, bucket by bucket."""
    result = []
    for (le_pre, c_pre), (le_post, c_post) in zip(pre, post):
        result.append((le_post, max(0.0, c_post - c_pre)))
    return result


# ---------------------------------------------------------------------------
# Scenario loading
# ---------------------------------------------------------------------------

def load_scenario(results_dir: str, scenario: str, nodes: int) -> tuple[dict, dict]:
    """Return (pre, post) merged dicts for a scenario."""
    def files_for(tag: str) -> list[str]:
        if nodes > 1:
            candidates = [
                os.path.join(results_dir, f"{tag}_n{n}.vars")
                for n in range(1, nodes + 1)
            ]
            found = [p for p in candidates if os.path.exists(p)]
            if found:
                return found
        # Fall back to un-suffixed file (single-node capture or legacy).
        return [os.path.join(results_dir, f"{tag}.vars")]

    pre_files  = files_for(f"pre_{scenario}")
    post_files = files_for(f"post_{scenario}")

    pre  = merge_vars(pre_files)
    post = merge_vars(post_files)
    return pre, post


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def ns_to_ms(ns: float) -> float:
    return ns / 1e6


def fmt(v, fmt_spec=',.2f') -> str:
    if math.isnan(v) or math.isinf(v):
        return '  n/a'
    return format(v, fmt_spec)


# ---------------------------------------------------------------------------
# Main analysis
# ---------------------------------------------------------------------------

def analyze(results_dir: str, scenarios: list[str], nodes: int) -> None:
    print(f"\nResults dir : {results_dir}")
    print(f"Nodes       : {nodes}")
    print(f"Scenarios   : {', '.join(scenarios)}")

    rows = []
    for sc in scenarios:
        pre, post = load_scenario(results_dir, sc, nodes)
        if not pre or not post:
            rows.append({'scenario': sc, 'missing': True})
            continue

        row = {'scenario': sc, 'missing': False}

        # ---- Raft-log commit latency histogram (the key per-Raft metric) ----
        lc_hist_name = 'raft_process_logcommit_latency'
        lc_pre_hist  = pre.get(lc_hist_name)
        lc_post_hist = post.get(lc_hist_name)
        lc_pre_cnt   = pre.get(f'{lc_hist_name}_count', 0)
        lc_post_cnt  = post.get(f'{lc_hist_name}_count', 0)
        lc_pre_sum   = pre.get(f'{lc_hist_name}_sum', 0)
        lc_post_sum  = post.get(f'{lc_hist_name}_sum', 0)

        d_lc_count = max(0, lc_post_cnt - lc_pre_cnt)
        d_lc_sum   = max(0, lc_post_sum - lc_pre_sum)

        if lc_pre_hist and lc_post_hist:
            d_buckets = delta_buckets(lc_pre_hist, lc_post_hist)
            row['lc_p50_ms']  = ns_to_ms(histogram_quantile(0.50, d_buckets))
            row['lc_p95_ms']  = ns_to_ms(histogram_quantile(0.95, d_buckets))
            row['lc_p99_ms']  = ns_to_ms(histogram_quantile(0.99, d_buckets))
        else:
            row['lc_p50_ms'] = row['lc_p95_ms'] = row['lc_p99_ms'] = float('nan')

        row['lc_avg_ms']  = ns_to_ms(d_lc_sum / d_lc_count) if d_lc_count else float('nan')
        row['lc_count']   = d_lc_count

        # ---- Pebble WAL bytes / fsyncs (store-wide, noisy but available) ----
        d_bytes  = max(0, post.get('storage_wal_bytes_written', 0)
                          - pre.get('storage_wal_bytes_written', 0))
        d_fsyncs = max(0, post.get('storage_wal_fsync_latency_count', 0)
                          - pre.get('storage_wal_fsync_latency_count', 0))

        row['wal_bytes_gb'] = d_bytes / 1e9
        row['wal_fsyncs']   = d_fsyncs

        rows.append(row)

    # ---- Table 1: Raft-log commit latency percentiles ----
    print()
    print("=== Raft-log commit latency (raft.process.logcommit.latency deltas) ===")
    print(f"  Units: ms.  Computed from per-run histogram bucket deltas (pre→post).")
    print(f"  This measures ONLY the Raft-log commit path (entries + HardState → disk).")
    print()
    hdr = f"{'scenario':<12} {'p50 (ms)':>10} {'p95 (ms)':>10} {'p99 (ms)':>10} {'avg (ms)':>10} {'commits':>10}"
    print(hdr)
    print('-' * len(hdr))
    for r in rows:
        sc = r['scenario']
        if r['missing']:
            print(f"  {sc}: (no pre/post files found)")
            continue
        if math.isnan(r.get('lc_p50_ms', float('nan'))):
            note = '  (no logcommit histogram — re-run to capture; showing avg only)'
            avg_s = fmt(r['lc_avg_ms']) if not math.isnan(r['lc_avg_ms']) else 'n/a'
            print(f"{sc:<12} {'n/a':>10} {'n/a':>10} {'n/a':>10} {avg_s:>10} {int(r['lc_count']):>10}  {note}")
        else:
            print(
                f"{sc:<12}"
                f" {fmt(r['lc_p50_ms']):>10}"
                f" {fmt(r['lc_p95_ms']):>10}"
                f" {fmt(r['lc_p99_ms']):>10}"
                f" {fmt(r['lc_avg_ms']):>10}"
                f" {int(r['lc_count']):>10}"
            )

    # ---- Table 2: Scalar scalars ----
    print()
    print("=== Scalar metrics (WAL bytes, Pebble fsyncs) ===")
    print(f"  WAL bytes = store-wide Pebble WAL; includes state-machine writes,")
    print(f"  memtable flushes, and log rotations — NOT just Raft-log entries.")
    print()
    hdr2 = f"{'scenario':<12} {'WAL (GB)':>10} {'fsyncs':>10}"
    print(hdr2)
    print('-' * len(hdr2))
    for r in rows:
        if r['missing']:
            continue
        print(
            f"{r['scenario']:<12}"
            f" {fmt(r['wal_bytes_gb']):>10}"
            f" {fmt(r['wal_fsyncs'], ',.0f'):>10}"
        )

    # ---- Derived capture fractions ----
    sc_map = {r['scenario']: r for r in rows if not r['missing']}
    if all(s in sc_map for s in ('baseline', 's1_p33', 's1_p100')):
        b   = sc_map['baseline']['lc_avg_ms']
        s1p = sc_map['s1_p33']['lc_avg_ms']
        s1u = sc_map['s1_p100']['lc_avg_ms']
        if not any(math.isnan(x) for x in (b, s1p, s1u)) and (b - s1u) > 0:
            cap_s1 = (b - s1p) / (b - s1u)
            print()
            print(f"=== Capture fractions (from avg commit latency) ===")
            print(f"  D1 capture @ p=1/3:   {cap_s1:.1%}  "
                  f"  [ (baseline - s1_p33) / (baseline - s1_p100) ]")
            if all(s in sc_map for s in ('s2_p33', 's2_p100')):
                s2p = sc_map['s2_p33']['lc_avg_ms']
                s2u = sc_map['s2_p100']['lc_avg_ms']
                if not any(math.isnan(x) for x in (s2p, s2u)) and (b - s2u) > 0:
                    cap_s2 = (b - s2p) / (b - s2u)
                    print(f"  D2 capture @ p=1/3:   {cap_s2:.1%}  "
                          f"  [ (baseline - s2_p33) / (baseline - s2_p100) ]")

    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    default_dir = os.path.join(os.path.dirname(__file__), 'phase2_scenario1_results')
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--results-dir', default=default_dir,
                   help='Path to results directory (default: %(default)s)')
    p.add_argument('--scenarios', default='baseline,s1_p33,s1_p100,s2_p33,s2_p100',
                   help='Comma-separated scenario names (default: %(default)s)')
    p.add_argument('--nodes', type=int, default=1, choices=[1, 2, 3],
                   help='Number of nodes captured (looks for _n1/_n2/_n3 files; default 1)')
    args = p.parse_args()

    scenarios = [s.strip() for s in args.scenarios.split(',') if s.strip()]
    analyze(args.results_dir, scenarios, args.nodes)


if __name__ == '__main__':
    main()
