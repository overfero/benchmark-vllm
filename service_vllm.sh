#!/usr/bin/env bash
# (Re)launches the vLLM server itself in a remote `screen` session
# ('vllm_serve'). Kills any stale vllm_serve screen/process first (in its
# own ssh call - see note below), writes the launch command to a script
# FILE and scp's it rather than inlining it over ssh (nested quoting of
# flags like --speculative-config breaks under `ssh ... "... | bash -c
# '...'"`), then waits on a real health check (T4 warmup is genuinely slow -
# 5-15 min observed - this is NOT a hang, don't kill early).
#
# Usage: ./service_vllm.sh --api-key '...' --host-alias Kaggle_Zrok8 \
#          [--ckpt-dir /models/qwen3_8b] [--served-model-name qwen3-8b] \
#          [--port 8000]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

CKPT_DIR="/models/qwen3_8b"
SERVED_MODEL_NAME="qwen3-8b"
VLLM_PORT=8000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="$2"; shift 2 ;;
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --ckpt-dir) CKPT_DIR="$2"; shift 2 ;;
    --served-model-name) SERVED_MODEL_NAME="$2"; shift 2 ;;
    --port) VLLM_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$API_KEY" ]] || { echo "need --api-key" >&2; exit 1; }

acquire_lock

# ALWAYS in its own ssh call, never combined with the launch command -
# `screen -dm bash -c '...vllm serve...'` run in the SAME ssh call as a
# prior `pkill -f "vllm serve"` can match and kill its own invoking shell
# before the launch even starts (pkill -f matches full argv, which includes
# the launch command's own text).
log "stopping any existing vllm_serve screen/process on $HOST_ALIAS..."
ssh_cmd "screen -S vllm_serve -X quit 2>/dev/null; pkill -f 'vllm serve' 2>/dev/null; true"
sleep 3

log "writing vLLM launch script..."
cat > /tmp/launch_vllm_${HOST_ALIAS}.sh << LAUNCHEOF
#!/bin/bash
source /root/miniconda3/etc/profile.d/conda.sh
conda activate vllm_qwen38
vllm serve $CKPT_DIR \\
  --served-model-name $SERVED_MODEL_NAME \\
  --tensor-parallel-size 2 \\
  --gpu-memory-utilization 0.9 \\
  --max-model-len 40960 \\
  --max-num-seqs 512 \\
  --api-key "$API_KEY" \\
  --host 0.0.0.0 --port $VLLM_PORT 2>&1 | tee /root/vllm_serve.log
LAUNCHEOF
scp_cmd /tmp/launch_vllm_${HOST_ALIAS}.sh "$HOST_ALIAS:/root/launch_vllm.sh"
ssh_cmd "chmod +x /root/launch_vllm.sh"

log "launching vLLM server (screen session 'vllm_serve')..."
ssh_cmd "screen -S vllm_serve -dm bash /root/launch_vllm.sh"

log "waiting for vLLM health check (observed 5-15 min on T4 - this is real warmup time, not a hang)..."
for i in $(seq 1 90); do
  code=$(ssh_cmd "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$VLLM_PORT/health 2>/dev/null" || true)
  if [[ "$code" == "200" ]]; then
    log "vLLM server is UP (health check passed after ~$((i * 10))s)"
    exit 0
  fi
  errline=$(ssh_cmd "grep -i 'traceback\|OutOfMemory\|CUDA error' /root/vllm_serve.log 2>/dev/null | tail -1" || true)
  if [[ -n "$errline" ]]; then
    log "ERROR detected in vLLM log: $errline"
    log "full log: /root/vllm_serve.log on $HOST_ALIAS"
    exit 1
  fi
  if [[ "$i" == "90" ]]; then
    log "ERROR: vLLM did not become healthy within 15 minutes - check /root/vllm_serve.log on $HOST_ALIAS"
    exit 1
  fi
  sleep 10
done
