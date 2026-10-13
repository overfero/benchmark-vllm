#!/usr/bin/env bash
# Deploys + (re)launches nccl_exporter.py (runs all_reduce_perf every 5 min,
# exposes NCCL bus-bandwidth as Prometheus metrics) in a remote screen
# session ('nccl_exporter'), on :9401/metrics. Needs nccl-tests already
# built (setup_cuda_tools.sh).
#
# Usage: ./service_nccl_exporter.sh --host-alias Kaggle_Zrok8

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

acquire_lock

log "deploying + launching NCCL bandwidth exporter (:9401/metrics) on $HOST_ALIAS..."
scp_cmd nccl_exporter.py "$HOST_ALIAS:/root/nccl_exporter.py"
ssh_cmd "screen -S nccl_exporter -X quit 2>/dev/null; screen -S nccl_exporter -dm python3 /root/nccl_exporter.py"
log "launched"
