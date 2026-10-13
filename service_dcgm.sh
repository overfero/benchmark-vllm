#!/usr/bin/env bash
# Installs (if needed) and launches DCGM's nv-hostengine in a remote screen
# session ('dcgm'). Idempotent: skips install if GPUs are already
# enumerable via dcgmi.
#
# Real fixes baked in here (from a real Zrok8 session):
#   - The apt-default `datacenter-gpu-manager` package resolves to 3.3.9,
#     which fails with NVML error 18 (LIB_RM_VERSION_MISMATCH) against a
#     recent R580 driver. Must purge it and install the versioned
#     `datacenter-gpu-manager-4-cuda12` package instead (per NVIDIA's
#     current install docs - the unsuffixed name is the OLD package).
#   - Even on DCGM 4, NVML can still fail to load if a STALE
#     libnvidia-ml.so (left over from an older base image layer in
#     /usr/lib/x86_64-linux-gnu/) resolves ahead of the real driver's copy
#     (/usr/local/nvidia/lib64/). Fix: point the system-default path's
#     symlinks at the correct versioned .so and re-run ldconfig.
#   - `nv-hostengine` run via bare `nohup ... &` dies silently when the ssh
#     session that spawned it closes - must run inside `screen`.
# The Profiling module (SM-occupancy fields) commonly fails to load even
# after this fix - needs perf-counter permissions this sandbox doesn't
# grant; accepted limitation. Core fields (temp/power/util/memory) work
# fine and are what gpu_exporter.py uses.
#
# Usage: ./service_dcgm.sh --host-alias Kaggle_Zrok8

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

log "checking DCGM (nv-hostengine) on $HOST_ALIAS..."
if ! ssh_cmd "pgrep -f nv-hostengine >/dev/null 2>&1 && dcgmi discovery -l 2>&1 | grep -q 'GPUs found (Active)' && ! dcgmi discovery -l 2>&1 | grep -q '^0 GPUs found'"; then
  log "DCGM not working yet - installing DCGM 4 + fixing NVML library resolution..."
  ssh_cmd "screen -S dcgm -X quit 2>/dev/null; pkill nv-hostengine 2>/dev/null; sleep 1; \
    dpkg --list datacenter-gpu-manager &>/dev/null && apt purge --yes datacenter-gpu-manager 2>&1 | tail -5; \
    apt-get update 2>&1 | tail -3 && apt-get install --yes --install-recommends datacenter-gpu-manager-4-cuda12 2>&1 | tail -20"
  log "fixing NVML library symlink (stale copy in /usr/lib/x86_64-linux-gnu/ wins over the real driver's otherwise)..."
  ssh_cmd "REAL_NVML=\$(find /usr/local/nvidia/lib64 -maxdepth 1 -iname 'libnvidia-ml.so.*' ! -name '*.so.1' ! -name '*.so' | head -1); \
    if [[ -n \"\$REAL_NVML\" ]]; then \
      rm -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.*.* 2>/dev/null; \
      ln -sf \"\$REAL_NVML\" /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 && \
      ln -sf libnvidia-ml.so.1 /usr/lib/x86_64-linux-gnu/libnvidia-ml.so && \
      ldconfig; \
    fi"
  log "launching nv-hostengine (screen session 'dcgm')..."
  ssh_cmd "screen -S dcgm -dm nv-hostengine -n --log-level WARN -f /root/dcgm.log --port 5555"
  sleep 3
  ssh_cmd "dcgmi discovery -l 2>&1" | grep -q "GPUs found (Active)" && log "DCGM: GPUs detected successfully" || log "WARNING: DCGM still not detecting GPUs - gpu_exporter.py will fall back to nvidia-smi"
else
  log "DCGM already working, skipping install"
fi
