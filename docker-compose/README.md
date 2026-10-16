# Docker Compose edition

Same security-layer stack as `../k8s/`, minus the Kubernetes-only tooling
(Kyverno, Velero, the operators - meaningless outside a K8s control plane).
vLLM itself is unchanged: still bare-metal on the Zrok VMs.

## Prerequisites

1. **SSH tunnels to the Zrok VMs must already be running** on this laptop
   (same ones used by the K8s version). Zrok9 now runs `laya-serve`
   (`../service_laya.sh`) instead of a second 8B vLLM model - Laya is a
   421M non-autoregressive classifier
   ([convaiinnovations/laya](https://huggingface.co/convaiinnovations/laya)),
   not a chat model, used here for content safety (`litellm/safety_guardrail.py`):
   ```
   ssh -N -L 18000:localhost:8000 Kaggle_Zrok8   # qwen3-8b-awq
   ssh -N -L 18001:localhost:8000 Kaggle_Zrok7   # qwen3-8b-awq (2nd replica)
   ssh -N -L 18002:localhost:8000 Kaggle_Zrok9   # laya-serve (content safety)
   ```
2. `cp .env.example .env` and fill in every `CHANGEME` (see comments in
   that file for which values must match the Zrok VMs' own vLLM `--api-key`
   values, and which are made-up-by-you secrets).

## Bring-up order

```bash
# 1. Everything except oauth2-proxy (needs a client secret that doesn't exist yet)
docker compose up -d $(docker compose config --services | grep -v oauth2-proxy)

# 2. Once Keycloak is up (~30s), create its realm/client/demo-user
./setup_keycloak_realm.sh
# -> paste the printed secret into .env as CHAT_DASHBOARD_CLIENT_SECRET

# 3. Now start the OIDC-fronted chat dashboard
docker compose up -d oauth2-proxy
```

## Where things land

| Service | URL |
|---|---|
| LiteLLM API (`/v1/chat/completions`, Bearer `LITELLM_MASTER_KEY`) | http://localhost:4000 |
| Chat dashboard (behind Keycloak login) | http://localhost:4180 |
| Langfuse UI | http://localhost:3000 |
| Keycloak admin console | http://localhost:8081 |
| OpenBao UI | http://localhost:8200 |

## Known gaps vs. the K8s version

- No Envoy Gateway equivalent in front of the `/v1/*` API - LiteLLM's own
  port is exposed directly. Fine for a POC; a real deployment would put
  nginx/Envoy/Traefik in front for TLS termination.
- No automated node-IP recovery (`fix_node_ip.sh`'s job) - if the laptop's
  IP changes, just re-run the SSH tunnel commands above, no cluster
  membership state to worry about since there's no etcd here at all.
