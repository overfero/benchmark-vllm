#!/usr/bin/env bash
# Orchestrator: runs every setup/service script in this repo in the right
# order to stand up the full stack on a remote 2xT4 host (Kaggle_Zrok7/
# Kaggle_Zrok8) - vLLM serve, chat dashboard, GuideLLM/Locust, DCGM, GPU
# exporter, NCCL exporter, Prometheus, Grafana (auto-provisioned dashboards).
#
# This replaces the old single qwen38_27b_zrok8_full_stack.sh monolith -
# same steps, same real fixes (see each sub-script's header for the exact
# bug it fixes), just split one-script-per-service so a routine restart of
# e.g. just Grafana doesn't have to re-read/re-run the whole pipeline.
#
# Usage: ./deploy_all.sh --api-key '...' [--host-alias Kaggle_Zrok8] [--service-only]
#   --service-only: skip setup_conda.sh/setup_vllm_install.sh/
#     setup_guidellm_model.sh/setup_cuda_tools.sh (assumes already done once)
#     and go straight to (re)launching every service - use this for every
#     routine restart once setup has succeeded once.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

SERVICE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="$2"; shift 2 ;;
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --service-only) SERVICE_ONLY=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$API_KEY" ]] || { echo "need --api-key (see --help)" >&2; exit 1; }

if [[ "$SERVICE_ONLY" -eq 0 ]]; then
  log "=== setup: conda envs ==="
  ./setup_conda.sh --host-alias "$HOST_ALIAS"

  # vLLM install, GuideLLM/Locust+model download, and cuda-tools build run
  # as three independent parallel jobs - real wall-clock win when more than
  # one actually needs to install something. GuideLLM/Locust+model download
  # are already kept sequential WITHIN setup_guidellm_model.sh (see its own
  # header) since both touch the same bench_tools env.
  log "=== setup: vLLM install / GuideLLM+model / cuda-tools (parallel) ==="
  LOG_DIR=$(mktemp -d)
  ./setup_vllm_install.sh --host-alias "$HOST_ALIAS" > "$LOG_DIR/vllm.log" 2>&1 & PID_VLLM=$!
  ./setup_guidellm_model.sh --host-alias "$HOST_ALIAS" > "$LOG_DIR/guidellm_model.log" 2>&1 & PID_GM=$!
  ./setup_cuda_tools.sh --host-alias "$HOST_ALIAS" > "$LOG_DIR/cuda_tools.log" 2>&1 & PID_CUDA=$!

  FAILED=0
  for pair in "vllm_install:$PID_VLLM" "guidellm_model:$PID_GM" "cuda_tools:$PID_CUDA"; do
    name="${pair%%:*}"; pid="${pair##*:}"
    if wait "$pid"; then
      log "parallel job '$name' finished OK"
    else
      log "parallel job '$name' FAILED - see $LOG_DIR/$name.log"
      cat "$LOG_DIR/$name.log" >&2
      FAILED=1
    fi
  done
  rm -rf "$LOG_DIR"
  [[ "$FAILED" -eq 0 ]] || { echo "FATAL: one or more parallel setup jobs failed (see above)" >&2; exit 1; }
else
  log "--service-only: skipping setup_conda/setup_vllm_install/setup_guidellm_model/setup_cuda_tools"
fi

log "=== service: vLLM serve ==="
./service_vllm.sh --api-key "$API_KEY" --host-alias "$HOST_ALIAS"

log "=== service: DCGM ==="
./service_dcgm.sh --host-alias "$HOST_ALIAS"

log "=== service: GPU exporter ==="
./service_gpu_exporter.sh --host-alias "$HOST_ALIAS"

log "=== service: NCCL exporter ==="
./service_nccl_exporter.sh --host-alias "$HOST_ALIAS"

log "=== service: Prometheus ==="
./service_prometheus.sh --host-alias "$HOST_ALIAS"

log "=== service: Grafana (+ dashboard provisioning) ==="
./service_grafana.sh --host-alias "$HOST_ALIAS"

log "=== service: chat UI ==="
./service_chat_ui.sh --host-alias "$HOST_ALIAS"

cat >&2 << SUMMARY

=== Full stack deployed on $HOST_ALIAS ===
  vLLM API    : http://127.0.0.1:8000  (model: qwen3-8b, api-key required)
  Chat UI     : http://127.0.0.1:8080  (SSE streaming chat, same-origin proxy to vLLM)
  Prometheus  : http://127.0.0.1:9090
  Grafana     : http://127.0.0.1:3000  (login admin/admin, change on first login)
                dashboards: gpu-dcgm-overview, vllm-bench-overview (auto-provisioned)
  GPU exporter: http://127.0.0.1:9400/metrics

Access from your local machine: forward these ports over SSH, e.g.
  ssh -L 3000:localhost:3000 -L 8080:localhost:8080 $HOST_ALIAS

Tool paths for benchmarking (run manually, not launched by this script):
  GuideLLM : conda activate bench_tools && guidellm ...
  Locust   : conda activate bench_tools && locust ...
  gpu-burn : /opt/gpu-burn/gpu_burn <seconds>
  nccl-tests: /opt/nccl-tests/build/all_reduce_perf -b 8 -e 128M -f 2 -g 2
SUMMARY
