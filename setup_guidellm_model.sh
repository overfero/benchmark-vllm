#!/usr/bin/env bash
# Installs GuideLLM/Locust into the bench_tools conda env AND downloads the
# model checkpoint - kept in ONE script, run sequentially, because both
# operate on the SAME bench_tools env (`uv pip install` writing into
# site-packages while `hf download`'s own imports read from it) and running
# them concurrently (e.g. from two separate scripts launched in parallel)
# reproduced a real hang this session: two processes hitting the same env at
# once deadlocked each other indefinitely (confirmed via /proc inspection -
# both stuck sleeping, neither making progress, for over an hour). Any two
# steps that `conda activate` the SAME env must never run concurrently.
#
# Usage: ./setup_guidellm_model.sh --host-alias Kaggle_Zrok8 \
#          [--hf-repo Qwen/Qwen3-8B] [--ckpt-dir /models/qwen3_8b]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

HF_REPO="Qwen/Qwen3-8B"
CKPT_DIR="/models/qwen3_8b"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --hf-repo) HF_REPO="$2"; shift 2 ;;
    --ckpt-dir) CKPT_DIR="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

acquire_lock

log "checking GuideLLM/Locust install on $HOST_ALIAS..."
# `timeout 20` server-side + MPLBACKEND=Agg: a bare `python -c 'import
# guidellm, locust'` was observed hanging INDEFINITELY this session (one
# instance sat alive for 10+ minutes with zero CPU use, no network issue, no
# colliding process) while the installed `guidellm` CLI entrypoint itself
# (`guidellm --help`) always returned instantly - points at a headless-env
# import-time hang (something probing for a display backend with no
# MPLBACKEND set). Fix: the CHECK itself must not be able to hang the whole
# script forever - timeout it and treat a timeout as "not confirmed
# installed" (falls through to reinstalling, cheap and idempotent if fine).
if ! ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda activate bench_tools && MPLBACKEND=Agg timeout 20 python -c 'import guidellm, locust' 2>/dev/null"; then
  log "installing GuideLLM + Locust + huggingface_hub..."
  ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda activate bench_tools && uv pip install guidellm locust -U huggingface_hub; echo EXIT_CODE=\$?" | grep -q 'EXIT_CODE=0' || {
    echo "FATAL: GuideLLM/Locust install failed" >&2; exit 1
  }
else
  log "GuideLLM/Locust already installed, skipping"
fi

log "checking model checkpoint ($CKPT_DIR)..."
if ! ssh_cmd "[[ -f $CKPT_DIR/config.json ]]"; then
  log "downloading checkpoint ($HF_REPO -> $CKPT_DIR)..."
  log "NOTE: using 'hf download', NOT 'huggingface-cli download' (deprecated, silently no-ops without downloading anything)"
  ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda activate bench_tools && mkdir -p \$(dirname $CKPT_DIR) && hf download $HF_REPO --local-dir $CKPT_DIR; echo EXIT_CODE=\$?" | grep -q 'EXIT_CODE=0' || {
    echo "FATAL: model download failed" >&2; exit 1
  }
  log "checkpoint downloaded OK"
else
  log "checkpoint already present, skipping download"
fi
