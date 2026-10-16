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
# [c]hat_proxy.py bracket trick: pkill -f matches full argv, which includes
# this very command's own text ("pkill -f 'chat_proxy.py'" literally
# contains "chat_proxy.py") - same self-match bug already found and fixed
# in service_vllm.sh this session, 100% reproducible, not a fluke.
ssh_cmd "screen -S chat_ui -X quit 2>/dev/null; pkill -f '[c]hat_proxy.py' 2>/dev/null; true"
sleep 2

# Written to a script FILE and scp'd rather than inlined over ssh, same
# reason as service_vllm.sh's launch script: nested quoting breaks under
# `ssh ... "... | bash -c '...'"`. Extracts the running vLLM server's own
# API key from its launch script (written by service_vllm.sh) - the key
# value itself never passes through THIS script's own stdout/context.
# vLLM requires it on every /v1/* call; the dashboard's JS never sends
# one, so chat_proxy.py injects it itself (see chat_proxy.py).
cat > /tmp/launch_chat_ui_${HOST_ALIAS}.sh << 'LAUNCHEOF'
#!/bin/bash
source /root/miniconda3/etc/profile.d/conda.sh
conda activate vllm_qwen38
export VLLM_API_KEY=$(grep -oP '(?<=--api-key ")[^"]+' /root/launch_vllm.sh)
python /root/chat_proxy.py 2>&1 | tee /root/chat_ui.log
LAUNCHEOF
scp_cmd /tmp/launch_chat_ui_${HOST_ALIAS}.sh "$HOST_ALIAS:/root/launch_chat_ui.sh"
ssh_cmd "chmod +x /root/launch_chat_ui.sh"
ssh_cmd "screen -S chat_ui -dm bash /root/launch_chat_ui.sh"
log "launched"
