#!/usr/bin/env bash
# Creates the two conda envs this stack needs on a remote 2xT4 host:
#   vllm_qwen38 (python 3.12, vLLM server)
#   bench_tools (python 3.11, GuideLLM/Locust/hf-hub)
# Idempotent: skips creation if both already exist.
#
# Real fix baked in: `conda create` can silently no-op on a fresh container -
# the Anaconda ToS gate blocks it, and piping through `| tail -N` masks the
# resulting non-zero exit code (tail's own exit code wins the pipeline).
# Fixed by accepting ToS first AND verifying with `conda env list` after,
# never trusting a piped command's exit code alone.
#
# Usage: ./setup_conda.sh --host-alias Kaggle_Zrok8

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

log "checking conda envs on $HOST_ALIAS..."
envs=$(ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda env list" 2>/dev/null || true)
if ! grep -q vllm_qwen38 <<<"$envs" || ! grep -q bench_tools <<<"$envs"; then
  log "creating conda envs (accepting ToS first - required on a fresh container)..."
  ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>&1 | tail -2 && \
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>&1 | tail -2 && \
    conda create -y -n vllm_qwen38 python=3.12 2>&1 | tail -2 && \
    conda create -y -n bench_tools python=3.11 2>&1 | tail -2"
  envs=$(ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda env list")
  grep -q vllm_qwen38 <<<"$envs" && grep -q bench_tools <<<"$envs" || {
    echo "FATAL: conda env creation did not actually succeed - see output above" >&2
    exit 1
  }
  log "conda envs created OK"
else
  log "conda envs already present, skipping creation"
fi
