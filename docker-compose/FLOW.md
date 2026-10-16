# Request flow — browser → chat UI → LiteLLM → guardrails → vLLM → back

The full path of one chat message, through every layer that touches it.
Services in the compose network are containers; the vLLM/Laya backends run
bare-metal on the remote Zrok VMs and are reached over SSH port-forwards.

```
┌─────────────────────────── LAPTOP (docker compose) ───────────────────────────┐
│                                                                                │
│  BROWSER                                                                       │
│    │  1. GET http://localhost:4180/                                            │
│    ▼                                                                           │
│  OAUTH2-PROXY (:4180)                                                          │
│    │  2. no session cookie? redirect to Keycloak (localhost:8080)              │
│    │     → user logs in (demo / see .env DEMO_LOGIN)                           │
│    │     → /oauth2/callback: code redeemed for tokens (redeem_url points at    │
│    │       keycloak:8080 on the compose network) → _oauth2_proxy cookie set    │
│    │  3. cookie valid → proxy to upstream                                      │
│    ▼                                                                           │
│  CHAT-UI (chat_proxy.py, FastAPI)                                              │
│    │  4. serves chat_dashboard.html ("Qwen3.5 Chat")                           │
│    │  5. user sends a message → JS POSTs /v1/chat/completions (same-origin)    │
│    │     chat_proxy.py injects Authorization: Bearer LITELLM_MASTER_KEY        │
│    │       (the key never reaches the browser)                                 │
│    ▼                                                                           │
│  LITELLM (:4000) ──── router / load balancer ────────────────────┐             │
│    │  6. GUARDRAIL pre_call: PRESIDIO PII                        │             │
│    │     - detects email/phone/credit-card/person → MASKed       │             │
│    │       before anything leaves the laptop                     │             │
│    │  7. GUARDRAIL during_call: LAYA SAFETY (async)              │             │
│    │     - sends the user message to Zrok11 /v1/systemone        │             │
│    │       (safe_laya 421M classifier, one forward pass)         │             │
│    │     - DECLINE → request REJECTED, never reaches the model   │             │
│    │  8. picks one deployment (round-robin):                     │             │
│    │       [0] qwen3-8b-awq → host.docker.internal:18000         │             │
│    │       [1] qwen3-8b-awq → host.docker.internal:18001         │             │
│    ▼                                                             │             │
└────┼─────────────────────────────────────────────────────────────┼─────────────┘
     │  9. ssh -N -L tunnel (local tmux sessions)                  │
     ▼                                                             ▼
┌─────────────────────┐          ┌─────────────────────┐   ┌──────────────────┐
│ ZROK10 (:18000)     │          │ ZROK9  (:18001)     │   │ ZROK11 (:18002)  │
│ vLLM qwen3-8b       │          │ vLLM qwen3-8b       │   │ laya-serve       │
│ TP=2 (2x T4)        │          │ TP=2 (2x T4)        │   │ safe_laya 421M   │
│ 10. prefill → KV    │          │ (replica)           │   │ ALLOW/DECLINE    │
│     cache → decode  │          │                     │   │ (1 forward pass) │
│ 11. streams tokens  │          │                     │   └──────────────────┘
│     as SSE chunks   │          │                     │
└────┬────────────────┘          └─────────────────────┘
     │
     │  12. RESPONSE PATH (returns along the same route, streaming):
     │      vLLM emits a token → SSE chunk {choices:[{delta:{content:"tok"}}]}
     │      → tunnel → LiteLLM (stream pass-through)
     │        → success_callback: writes the trace to LANGFUSE (audit log:
     │          original prompt, masked PII, latency, cost, which deployment)
     │        → chunk forwarded untouched to chat_proxy.py
     │      → oauth2-proxy (session cookie re-checked) → browser
     ▼
  BROWSER: JS appends every delta token into the chat bubble live
           (token-by-token, not waiting for the full answer)
```

## What each layer is actually responsible for

| Layer | Responsibility |
|---|---|
| oauth2-proxy | Browser AuthN (OIDC via Keycloak), session cookie, re-checked on every request |
| chat_proxy.py | Key injection (master key stays server-side), streaming pass-through |
| LiteLLM | API AuthN (Bearer), **load balancing** round-robin over 2 replicas, guardrails, audit |
| Presidio | PII masking **before** the prompt leaves the laptop |
| Laya (Zrok11) | Content safety **before** the prompt reaches the model — blocks, never modifies |
| vLLM (Zrok9/10) | Prefill → decode, continuous batching, SSE streaming |
| Langfuse | Records the whole request/response + guardrail metadata |

## Failure behavior

- Guardrail DECLINE or PII detected → the request stops at LiteLLM — the model
  never sees the original text — and a masked/declined response goes back to the
  browser. All of it is recorded as a Langfuse trace (http://localhost:3000).
- A replica dying mid-request → LiteLLM's router retries/fails over to the other
  deployment with the same `model_name`.
- An SSH tunnel dropping → that deployment starts failing health; requests keep
  succeeding via the other replica until the tunnel recovers.

## Bring-up order (from zero)

1. Zrok tunnels up (tmux `Kaggle_Zrok9/10/11` sessions), then SSH port-forwards
   (`vllm-tunnel-zrok9/10/11` tmux sessions, ports 18001/18000/18002).
2. VM services in their own remote `screen` sessions: `vllm_serve` on Zrok9/10
   (see `../service_vllm.sh`), `laya_serve` on Zrok11 (see `../service_laya.sh`).
3. `cp .env.example .env`, fill secrets, then:
   ```bash
   docker compose up -d $(docker compose config --services | grep -v oauth2-proxy)
   ./setup_keycloak_realm.sh          # once; realm/client/demo user
   # paste the printed secret into .env CHAT_DASHBOARD_CLIENT_SECRET
   docker compose up -d oauth2-proxy
   ```
4. Verify: request through LiteLLM lands a trace in Langfuse, and
   http://localhost:4180 shows the login page then the chat.
