#!/usr/bin/env bash
# Deploys + (re)launches gpu_exporter.py (real DCGM via dcgmi dmon, falls
# back to nvidia-smi) in a remote screen session ('gpu_exporter'), on
# :9400/metrics.
#
# Usage: ./service_gpu_exporter.sh --host-alias Kaggle_Zrok8

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

log "deploying + launching GPU exporter (DCGM-backed, :9400/metrics) on $HOST_ALIAS..."
scp_cmd gpu_exporter.py "$HOST_ALIAS:/root/gpu_exporter.py"
ssh_cmd "screen -S gpu_exporter -X quit 2>/dev/null; screen -S gpu_exporter -dm python3 /root/gpu_exporter.py"
log "launched"
