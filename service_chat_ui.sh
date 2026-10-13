#!/usr/bin/env bash
# Deploys + (re)launches the chat dashboard: a static HTML page
# (chat_dashboard.html, SSE streaming, markdown/LaTeX/code rendering,
# collapsible <think> block) served same-origin through a tiny FastAPI
# reverse proxy (chat_proxy.py) that forwards /v1/* + /health to the real
# vLLM backend on localhost - the page's own JS assumes same-origin
# (API_BASE = ""), so a plain static file server isn't enough; this needs
# genuine proxying. Runs in the vllm_qwen38 conda env since fastapi/httpx/
# uvicorn are already vLLM's own deps (no extra install needed).
#
# Usage: ./service_chat_ui.sh --host-alias Kaggle_Zrok8 [--port 8080]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

CHAT_PORT=8080

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --port) CHAT_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

acquire_lock

log "deploying chat dashboard (screen 'chat_ui', :$CHAT_PORT) on $HOST_ALIAS..."
scp_cmd chat_dashboard.html "$HOST_ALIAS:/root/chat_dashboard.html"
scp_cmd chat_proxy.py "$HOST_ALIAS:/root/chat_proxy.py"
ssh_cmd "screen -S chat_ui -X quit 2>/dev/null; pkill -f 'chat_proxy.py' 2>/dev/null; true"
sleep 2
ssh_cmd "source /root/miniconda3/etc/profile.d/conda.sh && conda activate vllm_qwen38 && screen -S chat_ui -dm bash -c 'python /root/chat_proxy.py 2>&1 | tee /root/chat_ui.log'"
log "launched"
