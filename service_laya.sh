#!/usr/bin/env bash
# (Re)launches Laya's self-hosted guard server in a remote `screen` session
# ('laya_serve'), on the Zrok VM that used to run the separate
# Llama-Guard-3-8B-AWQ vLLM instance (Zrok9). Laya is a 421M non-autoregressive
# "System 1" classifier (https://huggingface.co/convaiinnovations/laya), not
# an OpenAI chat model - it answers typed ALLOW/DECLINE questions in one
# forward pass instead of generating text, so it replaces the whole
# vLLM-serving-an-8B-guard-model approach. The fine-tuned safety checkpoint
# (https://huggingface.co/Dipto084/safe_laya) is registered via
# LAYA_EXTRA_MODELS so clients can request it by name over laya-serve's
# Jev-compatible /v1/systemone HTTP contract.
#
# Same operational pattern as service_vllm.sh: kill stale screen/process in
# its own ssh call (pkill -f self-match bug - see that script's comment),
# write the launch command to a file and scp it rather than inlining nested
# quoting over ssh, then wait on a real HTTP health check.
#
# Usage: ./service_laya.sh --api-key '...' --host-alias Kaggle_Zrok9 \
#          [--port 8000]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

LAYA_PORT=8000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="$2"; shift 2 ;;
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --port) LAYA_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$API_KEY" ]] || { echo "need --api-key" >&2; exit 1; }

acquire_lock

log "stopping any existing laya_serve screen/process on $HOST_ALIAS..."
ssh_cmd "screen -S laya_serve -X quit 2>/dev/null; pkill -f '[l]aya-serve' 2>/dev/null; true"
sleep 3

log "ensuring laya[serve] is installed on $HOST_ALIAS..."
ssh_cmd "python3 -m pip install -q -U 'laya[serve]'"

log "writing laya-serve launch script..."
cat > /tmp/launch_laya_${HOST_ALIAS}.sh << LAUNCHEOF
#!/bin/bash
export LAYA_HOST=0.0.0.0
export LAYA_PORT=$LAYA_PORT
export LAYA_DEVICE=cuda
export LAYA_API_KEY="$API_KEY"
export LAYA_EXTRA_MODELS='{"safe-laya": "Dipto084/safe_laya"}'
export LAYA_MODELS=safe-laya
export LAYA_PRELOAD=1
laya-serve 2>&1 | tee /root/laya_serve.log
LAUNCHEOF
scp_cmd /tmp/launch_laya_${HOST_ALIAS}.sh "$HOST_ALIAS:/root/launch_laya.sh"
ssh_cmd "chmod +x /root/launch_laya.sh"

log "launching laya-serve (screen session 'laya_serve')..."
ssh_cmd "screen -S laya_serve -dm bash /root/launch_laya.sh"

log "waiting for laya-serve health check (first boot downloads the safe_laya checkpoint - can take a few minutes)..."
for i in $(seq 1 60); do
  code=$(ssh_cmd "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$LAYA_PORT/v1/systemone \
    -H 'Authorization: Bearer $API_KEY' -H 'content-type: application/json' \
    -d '{\"state\":{\"body\":\"health check\"},\"model\":\"safe-laya\",\"questions\":{\"ok\":{\"type\":\"noul\",\"instructions\":\"is this a test\"}}}' \
    2>/dev/null" || true)
  if [[ "$code" == "200" ]]; then
    log "laya-serve is UP (health check passed after ~$((i * 5))s)"
    exit 0
  fi
  errline=$(ssh_cmd "grep -i 'traceback\|OutOfMemory\|CUDA error' /root/laya_serve.log 2>/dev/null | tail -1" || true)
  if [[ -n "$errline" ]]; then
    log "ERROR detected in laya-serve log: $errline"
    log "full log: /root/laya_serve.log on $HOST_ALIAS"
    exit 1
  fi
  if [[ "$i" == "60" ]]; then
    log "ERROR: laya-serve did not become healthy within 5 minutes - check /root/laya_serve.log on $HOST_ALIAS"
    exit 1
  fi
  sleep 5
done
