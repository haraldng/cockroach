#!/usr/bin/env bash
# run_aws_bench.sh — validate quorum-sync simulation results on real AWS EBS.
#
# Loops over three EBS disk tiers (gp3-base, gp3-max, st1), runs the full
# scenario matrix from phase2_scenario1.sh at two block sizes (128 B and
# 64 KB), then pulls results into raw-results-aws-<date>/.
#
# Prerequisites:
#   - roachprod installed and authenticated (AWS credentials set)
#   - A cockroach binary for the local machine (workload init/run) at $BINARY
#   - A Linux/amd64 binary to stage on the cluster, either via $BINARY_LINUX
#     or by letting roachprod download a released build.
#
# Building a Linux binary on macOS:
#   ./dev build cockroach --cross=linux
#   # output: artifacts/cockroach.linux-2.6.32-gnu-amd64
#
# Usage:
#   BINARY=./cockroach \
#   BINARY_LINUX=./artifacts/cockroach.linux-2.6.32-gnu-amd64 \
#   CLUSTER_PREFIX=yourname \
#     ./run_aws_bench.sh
#
# Optional env overrides:
#   BINARY          Local cockroach binary for workload init/run (default: ~/cockroach).
#   BINARY_LINUX    Linux/amd64 binary to upload to each cluster node via
#                   roachprod put. If unset, uses roachprod stage to fetch a
#                   released build (see COCKROACH_VERSION).
#   CLUSTER_PREFIX  Prefix for roachprod cluster names (default: $USER).
#   RESULTS_BASE    Where to write results (default: raw-results-aws-<date>).
#   SKIP_DESTROY    Set to "true" to leave clusters alive after each tier.
#   COCKROACH_VERSION Version tag for roachprod stage (ignored when BINARY_LINUX
#                   is set; default: latest released build).
#   AWS_TIERS       Space-separated tier specs to run. Each entry is
#                   "tier-name:ebs-type:iops:throughput".
#   BLOCK_BYTES_LIST Space-separated block sizes to run (default: "128 65536").
#   AWS_CONFIG      Path to roachprod AWS config JSON file. Use this when your
#                   account has different VPC/subnet/security-group IDs than
#                   Cockroach's embedded defaults.
#   AWS_ZONES       Comma-separated AWS zones (for example: "us-east-2a").
#   AWS_IAM_PROFILE IAM instance profile name for launched instances. Set to an
#                   empty string to disable attaching an instance profile.

set -euo pipefail

BINARY="${BINARY:-$HOME/cockroach}"
CLUSTER_PREFIX="${CLUSTER_PREFIX:-${USER}}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE2_SCRIPT="$SCRIPT_DIR/../../phase2_scenario1.sh"
DATE="$(date +%Y%m%d-%H%M%S)"
RESULTS_BASE="${RESULTS_BASE:-$SCRIPT_DIR/../raw-results-aws-${DATE}}"
SKIP_DESTROY="${SKIP_DESTROY:-false}"
BINARY_LINUX="${BINARY_LINUX:-}"
COCKROACH_VERSION="${COCKROACH_VERSION:-}"
NODE_COUNT=3  # CRDB nodes; node 4 is the workload driver
AWS_CONFIG="${AWS_CONFIG:-}"
AWS_ZONES="${AWS_ZONES:-}"
AWS_IAM_PROFILE="${AWS_IAM_PROFILE:-}"

# ---------------------------------------------------------------------------
# Disk tier definitions
# Each entry: "tier-name:ebs-type:iops:throughput"
# iops/throughput of 0 means "use EBS default" (applies to st1).
# ---------------------------------------------------------------------------
DEFAULT_AWS_TIERS=(
  "gp3-base:gp3:3000:125"
  "gp3-max:gp3:16000:1000"
  "st1:st1:0:0"
)

if [[ -n "${AWS_TIERS:-}" ]]; then
  # shellcheck disable=SC2206 # Intentional space-separated env override.
  TIERS=($AWS_TIERS)
else
  TIERS=("${DEFAULT_AWS_TIERS[@]}")
fi

# shellcheck disable=SC2206 # Intentional space-separated env override.
BLOCK_BYTES_VALUES=(${BLOCK_BYTES_LIST:-128 65536})

mkdir -p "$RESULTS_BASE"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# ---------------------------------------------------------------------------
# create_cluster <tier-name> <ebs-type> <iops> <throughput>
# Spins up a 4-node cluster (3 CRDB + 1 workload) on m6i.4xlarge with the
# given EBS configuration. Stages the cockroach binary on all nodes.
# ---------------------------------------------------------------------------
create_cluster() {
  local tier="$1" ebs_type="$2" iops="$3" tput="$4"
  local cluster="${CLUSTER_PREFIX}-qsync-${tier}"

  log "Creating cluster $cluster (EBS: $ebs_type iops=$iops tput=$tput)..."

  local ebs_flags="--aws-ebs-volume-type=$ebs_type --aws-ebs-volume-size=500"
  if [[ "$ebs_type" == "gp3" ]]; then
    ebs_flags+=" --aws-ebs-iops=$iops --aws-ebs-throughput=$tput"
  fi
  local aws_config_flag=""
  local aws_zones_flag=""
  local aws_iam_profile_flag=""
  if [[ -n "$AWS_CONFIG" ]]; then
    aws_config_flag="--aws-config=$AWS_CONFIG"
  fi
  if [[ -n "$AWS_ZONES" ]]; then
    aws_zones_flag="--aws-zones=$AWS_ZONES"
  fi
  # Accept either a real profile name or an explicit empty string to disable.
  if [[ -n "${AWS_IAM_PROFILE+x}" ]]; then
    aws_iam_profile_flag="--aws-iam-profile=$AWS_IAM_PROFILE"
  fi

  roachprod create "$cluster" \
    --clouds=aws \
    --nodes=$((NODE_COUNT + 1)) \
    --aws-machine-type="m6i.4xlarge" \
    $aws_config_flag \
    $aws_zones_flag \
    $aws_iam_profile_flag \
    $ebs_flags \
    --lifetime=8h

  log "Staging cockroach binary on $cluster..."
  if [[ -n "$BINARY_LINUX" ]]; then
    # Upload the locally-built Linux binary (e.g. from ./dev build --cross=linux).
    roachprod put "$cluster" "$BINARY_LINUX" cockroach
    roachprod run "$cluster" -- "chmod +x ~/cockroach"
  elif [[ -n "$COCKROACH_VERSION" ]]; then
    roachprod stage "$cluster" cockroach "$COCKROACH_VERSION"
  else
    roachprod stage "$cluster" cockroach
  fi

  log "Starting CockroachDB on nodes 1-$NODE_COUNT..."
  roachprod start "$cluster:1-$NODE_COUNT" --secure=false

  log "Cluster $cluster ready."
}

# ---------------------------------------------------------------------------
# destroy_cluster <cluster>
# ---------------------------------------------------------------------------
destroy_cluster() {
  local cluster="$1"
  if [[ "$SKIP_DESTROY" == "true" ]]; then
    log "SKIP_DESTROY=true — leaving cluster $cluster alive."
    return
  fi
  log "Destroying cluster $cluster..."
  roachprod destroy "$cluster"
}

# ---------------------------------------------------------------------------
# run_tier <tier-name> <cluster>
# Runs the full scenario matrix at both block sizes against an already-running
# cluster, writing results into $RESULTS_BASE/<tier-name>/.
# ---------------------------------------------------------------------------
run_tier() {
  local tier="$1" cluster="$2"
  local tier_dir="$RESULTS_BASE/$tier"
  mkdir -p "$tier_dir"

  log "=== Tier: $tier  Cluster: $cluster ==="

  for block_bytes in "${BLOCK_BYTES_VALUES[@]}"; do
    local label="${block_bytes}B"
    local run_dir="$tier_dir/bs${label}"
    mkdir -p "$run_dir"

    log "--- block size: ${label} ---"

    CLUSTER="$cluster" \
    BLOCK_BYTES="$block_bytes" \
    NODE_COUNT="$NODE_COUNT" \
    RESULTS_DIR="$run_dir" \
    ALL_NODES="true" \
      bash "$PHASE2_SCRIPT" "$BINARY"

    log "Results for $tier / $label written to $run_dir"
  done
}

# ---------------------------------------------------------------------------
# Main: iterate over tiers
# ---------------------------------------------------------------------------
log "AWS EBS benchmark run starting. Results → $RESULTS_BASE"
log "Tiers: ${#TIERS[@]}, scenarios: 5, block sizes: ${#BLOCK_BYTES_VALUES[@]} → $((${#TIERS[@]} * 5 * ${#BLOCK_BYTES_VALUES[@]})) total runs"
echo ""

for tier_spec in "${TIERS[@]}"; do
  IFS=: read -r tier ebs_type iops tput <<< "$tier_spec"

  cluster_name="${CLUSTER_PREFIX}-qsync-${tier}"
  create_cluster "$tier" "$ebs_type" "$iops" "$tput"
  run_tier "$tier" "$cluster_name"
  destroy_cluster "$cluster_name"

  echo ""
  log "Tier $tier complete."
  echo ""
done

log "All tiers complete. Raw results in $RESULTS_BASE"
echo ""
cat <<'NEXT'
Next steps:
  1. For each tier, run analyze_vars.py against the tier results dir:

       python3 bench_tier_a/analyze_vars.py \
         --results-dir raw-results-aws-<date>/<tier>/bs128B \
         --nodes 3

  2. Compare the per-tier Raft commit latency tables against the sim baseline
     in bench_tier_a/sim_disk/benchmark_summary.md.

  3. Check predictions:
       aws-st1        → s1_p33 workload throughput ≥ +100%,  D1 capture ≥ 0.25
       aws-gp3-base   → s1_p33 workload throughput ≥ +20%
       aws-gp3-max    → small/negative D1 capture (artifact-dominated, expected)

  4. Update benchmark_summary.md with a "Sim vs AWS" comparison table.
NEXT
