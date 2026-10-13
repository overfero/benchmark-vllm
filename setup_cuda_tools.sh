#!/usr/bin/env bash
# Builds gpu-burn (stress test) and nccl-tests (all_reduce_perf, used by
# nccl_exporter.py) on the remote host. Needs no Python/conda env at all.
# Checks for an existing nvcc FIRST before apt-installing cuda-toolkit (a
# multi-GB, ~10+ min download for nothing) - T4 base images here already
# have nvcc at /usr/local/cuda-*/bin/nvcc.
#
# Usage: ./setup_cuda_tools.sh --host-alias Kaggle_Zrok8

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

log "checking for an existing nvcc before installing anything..."
cuda_bin=$(ssh_cmd "for d in /usr/local/cuda-*/bin; do [[ -x \$d/nvcc ]] && echo \$d && break; done" || true)
if [[ -z "$cuda_bin" ]]; then
  log "no nvcc found anywhere - installing cuda-toolkit via apt (slow, multi-GB)..."
  ssh_cmd "apt-get update 2>&1 | tail -3 && apt-get install -y cuda-toolkit-12-6 2>&1 | tail -20"
  cuda_bin="/usr/local/cuda-12.6/bin"
else
  log "found existing nvcc at $cuda_bin/nvcc - skipping cuda-toolkit install"
fi

log "checking gpu-burn build..."
if ! ssh_cmd "[[ -x /opt/gpu-burn/gpu_burn ]]"; then
  log "cloning + building gpu-burn..."
  ssh_cmd "export PATH=$cuda_bin:\$PATH && export CUDA_HOME=\$(dirname $cuda_bin) && cd /opt && \
    git clone https://github.com/wilicc/gpu-burn.git 2>&1 | tail -3 && cd gpu-burn && make 2>&1 | tail -10"
else
  log "gpu-burn already built, skipping"
fi

log "checking nccl-tests build..."
if ! ssh_cmd "[[ -x /opt/nccl-tests/build/all_reduce_perf ]]"; then
  log "cloning + building nccl-tests (needs libnccl-dev, usually already present)..."
  ssh_cmd "export PATH=$cuda_bin:\$PATH && export CUDA_HOME=\$(dirname $cuda_bin) && cd /opt && \
    git clone https://github.com/NVIDIA/nccl-tests.git 2>&1 | tail -3 && cd nccl-tests && make 2>&1 | tail -10"
else
  log "nccl-tests already built, skipping"
fi
