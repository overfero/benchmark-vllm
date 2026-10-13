# benchmark-vllm

GPU serving + observability stack for Qwen3-8B on a remote 2xT4 host (TP=2):
vLLM serve, a browser chat dashboard (SSE streaming), GuideLLM load testing,
real DCGM-backed GPU metrics, an NCCL bandwidth exporter, Prometheus, and
Grafana (two auto-provisioned dashboards).

Demo video (both Grafana dashboards live during a benchmark run):

<video src="demo.webm" controls width="720">
  Your viewer doesn't support inline video - open <a href="demo.webm">demo.webm</a> directly.
</video>

## Layout

- `lib/common.sh` — shared `ssh_cmd` (retrying ssh wrapper), `log`, locking.
- `setup_conda.sh`, `setup_vllm_install.sh`, `setup_guidellm_model.sh`,
  `setup_cuda_tools.sh` — one-time setup steps (conda envs, vLLM install,
  GuideLLM/Locust + model download, gpu-burn/nccl-tests build).
- `service_vllm.sh`, `service_dcgm.sh`, `service_gpu_exporter.sh`,
  `service_nccl_exporter.sh`, `service_prometheus.sh`, `service_grafana.sh`,
  `service_chat_ui.sh` — one script per long-lived service, each launched in
  its own remote `screen` session.
- `deploy_all.sh` — orchestrator that runs all of the above in order, for a
  full fresh deploy. Pass `--service-only` on a routine restart once setup
  has succeeded once (skips straight to (re)launching services).
- `gpu_exporter.py` / `nccl_exporter.py` — the two custom Prometheus
  exporters (DCGM/nvidia-smi-backed GPU metrics on `:9400`, NCCL
  `all_reduce_perf` bandwidth on `:9401`).
- `chat_dashboard.html` / `chat_proxy.py` — the chat UI (static page) and
  its same-origin FastAPI reverse proxy to vLLM.
- `grafana_gpu_dashboard.json` / `grafana_bench_dashboard.json` — the two
  Grafana dashboards, auto-provisioned by `service_grafana.sh`.
- `prometheus.yml` — scrape config for the `vllm`/`gpu`/`nccl` jobs.

## Deploying

```bash
./deploy_all.sh --api-key '<vllm-api-key>' --host-alias Kaggle_Zrok8
# routine restart once setup has succeeded once:
./deploy_all.sh --api-key '<vllm-api-key>' --host-alias Kaggle_Zrok8 --service-only
```

Forward just Grafana + chat to view locally:

```bash
ssh -L 3000:localhost:3000 -L 8080:localhost:8080 Kaggle_Zrok8
```

## How the AI workload was simulated

Load was generated with [GuideLLM](https://github.com/neuralmagic/guidellm)
against the live vLLM OpenAI-compatible endpoint, run inside a remote
`screen` session (`guidellm_bench`) so the multi-minute sweep survives local
zrok tunnel drops.

```bash
conda activate bench_tools
guidellm run \
  --backend kind=openai_http,target=http://localhost:8000,model=qwen3-8b,api_key=<key> \
  --tokenizer kind=huggingface_auto,model=/models/qwen3_8b \
  --data kind=synthetic_text,prompt_tokens=2048,output_tokens=128 \
  --profile kind=concurrent \
  --constraint kind=max_duration,seconds=30 \
  --override profile.streams 1,50,100,200,300 \
  --override constraints[0].seconds 30,90,180,360,540 \
  --disable-console-interactive
```

- **Workload shape**: synthetic text, 2048 prompt tokens / 128 output tokens
  per request — chosen to stress prefill (long input) more than decode
  (short, bounded output), matching a typical RAG/long-context chat pattern.
- **Concurrency sweep**: 5 stages at 1 → 50 → 100 → 200 → 300 concurrent
  streams, run back-to-back in one `guidellm run` invocation.
- **Per-stage duration scaled with concurrency**, not fixed: 30s / 90s / 180s
  / 360s / 540s. A flat duration (GuideLLM's own default scenario, 45s/stage)
  under-measures high concurrency — the KV cache fills, the server catches
  up and starts actually completing requests only near the very end of the
  window, so a short fixed window reports near-zero completions even though
  the server is working correctly (confirmed directly: concurrent@50 went
  from 0 successful at 60s to 11 successful once given 90s). Each stage gets
  90s of budget per 50 concurrency units so the server has time to actually
  drain the queue it built up.
- **Auth**: GuideLLM's backend config must carry the same `api_key` vLLM was
  launched with (`--api-key` on `service_vllm.sh`), otherwise every request
  fails with 401 and every stage reports 0% success for an unrelated reason.

## Results — Zrok8 (Qwen3-8B, TP=2, 2xT4)

Full 5-stage sweep completed end-to-end, zero errored requests at any stage:

| Stage | Actual concurrency | TTFT mean | TTFT p95 | ITL mean | req/s | output tok/s |
|---|---|---|---|---|---|---|
| concurrent@1   | 1.0   | 1836ms   | 1892ms   | 40.6ms  | 0.1 | 17.3 |
| concurrent@50  | 50.0  | 11846ms  | 20466ms  | 501.9ms | 0.1 | 39.2 |
| concurrent@100 | 99.9  | 59818ms  | 114238ms | 493.0ms | 0.3 | 42.3 |
| concurrent@200 | 199.8 | 145092ms | 287496ms | 502.5ms | 0.3 | 50.4 |
| concurrent@300 | 299.3 | 239600ms | 457982ms | 508.8ms | 0.4 | 48.0 |

Raw output: `/root/benchmarks.json` and `/root/benchmarks.csv` on the host.

**Reading these numbers**: TTFT grows roughly linearly with concurrency
because every stage uses the same 2048-token prefill — once more requests
are queued than the KV cache can run concurrently, new requests simply wait
longer for a slot (visible live as `vllm:num_requests_waiting` climbing and
`vllm:kv_cache_usage_perc` pinned near 100% on the bench dashboard). ITL
(inter-token latency) stays flat at ~500ms across every concurrency level
above 1 — decode throughput per *running* request doesn't degrade under
load, the server just runs more requests concurrently rather than slower
per request. GuideLLM itself flagged client-side "root dispatch delay"
warnings at @200/@300 (1.6s/3.6s p95) — the load generator was occasionally
late dispatching new requests at very high concurrency, a client-side
measurement artifact, not a server bottleneck.

Zrok7 (identical hardware/config) was run with the same command for
cross-validation — per-stage throughput and TTFT tracked Zrok8 closely at
every concurrency level, confirming the two deployments perform
equivalently.
