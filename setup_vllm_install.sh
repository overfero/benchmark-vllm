#!/usr/bin/env bash
# Installs vLLM into the vllm_qwen38 conda env (must already exist - run
# setup_conda.sh first). Idempotent: skips if `import vllm` already works.
#
# Usage: ./setup_vllm_install.sh --host-alias Kaggle_Zrok8

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

log "checking vLLM install on $HOST_ALIAS..."
if ! ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda activate vllm_qwen38 && python -c 'import vllm' 2>/dev/null"; then
  log "installing vLLM (uv, several GB, can take a few minutes)..."
  ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda activate vllm_qwen38 && uv pip install vllm --torch-backend=auto; echo EXIT_CODE=\$?" | grep -q 'EXIT_CODE=0' || {
    echo "FATAL: vLLM install failed" >&2; exit 1
  }
  log "vLLM installed OK"
else
  log "vLLM already installed, skipping"
fi
