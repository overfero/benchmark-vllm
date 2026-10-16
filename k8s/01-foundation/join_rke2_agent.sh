#!/usr/bin/env bash
# Joins a remote host as an RKE2 AGENT (worker node) to the RKE2 server
# running on this laptop (install_rke2_server.sh). Works identically
# whether --host-alias is a real Kaggle_Zrok7/Kaggle_Zrok8 VM or a local
# dev-harness FakeNodeN container (k8s/dev-harness/up.sh) - same ssh_cmd
# path either way, which is the whole point of the dev-harness.
#
# ALWAYS validate against a FakeNodeN first:
#   ../dev-harness/up.sh 1
#   ./join_rke2_agent.sh --host-alias FakeNode1
#   kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes   # confirm Ready
#   ../dev-harness/down.sh 1
# before ever running this against Kaggle_Zrok7/Kaggle_Zrok8 - those VMs
# are quota-limited and the tunnel is known-flaky, a bug caught here is
# free, a bug caught there costs real compute/time.
#
# Requires: install_rke2_server.sh already run on this laptop, AND (for
# real Kaggle_Zrok* hosts, not needed for local FakeNode* ones which share
# the laptop's network namespace... actually they don't either, see below)
# setup_remote_forward.sh already run + SSH session reconnected.
#
# Usage: ./join_rke2_agent.sh --host-alias <Kaggle_Zrok7|Kaggle_Zrok8|FakeNode1>

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source lib/common.sh

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

acquire_lock

RKE2_KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="$PATH:/var/lib/rancher/rke2/bin"
export KUBECONFIG="$RKE2_KUBECONFIG"

# Reads from a user-readable copy (~/.rke2-node-token, 0640, owned by the
# invoking user) rather than the original root-only 0600
# /var/lib/rancher/rke2/server/node-token - avoids needing an interactive
# sudo prompt on every single join (this Bash tool can't supply one
# anyway). One-time setup: sudo install -m 0640 -o $USER
# /var/lib/rancher/rke2/server/node-token ~/.rke2-node-token
TOKEN_FILE="$HOME/.rke2-node-token"
[[ -f "$TOKEN_FILE" ]] || {
  echo "FATAL: $TOKEN_FILE not found. Run once:" >&2
  echo "  sudo install -m 0640 -o \$USER /var/lib/rancher/rke2/server/node-token $TOKEN_FILE" >&2
  exit 1
}
NODE_TOKEN=$(cat "$TOKEN_FILE")

# The agent connects to the server at https://127.0.0.1:9345 FROM THE
# AGENT'S OWN PERSPECTIVE. For a FakeNodeN dev-harness container, that
# "127.0.0.1" is the CONTAINER's own loopback - which is NOT the laptop's
# loopback (separate network namespace), so this only works there via the
# container's port-forward (-p 127.0.0.1:<port>:22 was for SSH; the RKE2
# port needs its own reachable path). For the dev-harness case we instead
# point the agent at the laptop's real LAN/docker-bridge IP. For the real
# Kaggle_Zrok7/Kaggle_Zrok8 case, 127.0.0.1:9345 on the remote genuinely
# tunnels back to the laptop via the SSH RemoteForward set up in
# setup_remote_forward.sh - that's the whole reason that script exists.
if [[ "$HOST_ALIAS" == FakeNode* ]]; then
  # docker0 bridge IP is reachable from inside any container on the
  # default bridge network - good enough for the dev-harness smoke test.
  LAPTOP_ADDR=$(ip -4 addr show docker0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  [[ -n "$LAPTOP_ADDR" ]] || { echo "FATAL: could not determine docker0 bridge IP - is Docker running?" >&2; exit 1; }
  RKE2_URL="https://$LAPTOP_ADDR:9345"
  log "dev-harness mode: agent will reach the server via docker0 bridge ($RKE2_URL)"
else
  RKE2_URL="https://127.0.0.1:9345"
  log "real-host mode: agent will reach the server via the SSH RemoteForward ($RKE2_URL) - make sure setup_remote_forward.sh has run and the SSH session to $HOST_ALIAS was reconnected after it"
fi

# Real bug hit against the ACTUAL Kaggle_Zrok7 VM (not just the FakeNode
# dev-harness): these Kaggle "VMs" are themselves Docker containers without
# systemd as PID 1 ("System has not been booted with systemd as init
# system (PID 1). Can't operate." - confirmed via a real run). The
# dev-harness's assumption that only FakeNode* needs container-specific
# workarounds was WRONG - detect this directly instead of trusting the
# hostname/alias naming, since any host (real or fake) might turn out to
# be a container. Container-mode hosts need: snapshotter: native (overlay-
# on-overlay isn't mountable) AND launching rke2 agent via `screen`
# directly instead of systemd (matching this project's established
# pattern for every other long-lived process on these VMs - vllm_serve,
# prometheus, grafana, etc. - for the exact same underlying reason).
# Probe the EXACT operation install.sh itself performs (`systemctl
# daemon-reload`) rather than a heuristic like `is-system-running` - that
# one is unreliable here: it printed "offline" (exit 1) on Kaggle_Zrok7,
# which looks like a real failure string-wise but isn't the same as the
# actual fatal "Failed to connect to bus: Host is down" daemon-reload
# hits - confirmed by testing both directly on this host.
log "detecting whether $HOST_ALIAS has a working systemd (determines install/launch method)..."
if ssh_cmd "systemctl daemon-reload" >/dev/null 2>&1; then
  CONTAINER_MODE=0
  log "$HOST_ALIAS has systemd - using rke2-agent.service"
else
  CONTAINER_MODE=1
  log "$HOST_ALIAS has NO usable systemd (container) - will launch rke2 agent via screen instead"
fi

log "checking for an existing rke2-agent on $HOST_ALIAS..."
if [[ "$CONTAINER_MODE" -eq 1 ]]; then
  ALREADY_RUNNING=$(ssh_cmd "screen -ls 2>/dev/null | grep -q rke2_agent && echo yes || echo no")
else
  ALREADY_RUNNING=$(ssh_cmd "systemctl is-active --quiet rke2-agent 2>/dev/null && echo yes || echo no")
fi

if [[ "$ALREADY_RUNNING" == "yes" ]]; then
  log "rke2-agent already running on $HOST_ALIAS, skipping install"
else
  log "installing RKE2 agent on $HOST_ALIAS (downloads the official install script there)..."
  # INSTALL_RKE2_SKIP_RELOAD is the REAL documented flag (confirmed by
  # reading install.sh itself - no SKIP_ENABLE/SKIP_START var exists). It
  # skips `systemctl daemon-reload`, which is what actually throws "System
  # has not been booted with systemd... Failed to connect to bus" on these
  # systemd-less Kaggle containers - the rest of the install (binary
  # unpack) succeeds fine either way.
  SKIP_RELOAD_FLAG=""
  [[ "$CONTAINER_MODE" -eq 1 ]] && SKIP_RELOAD_FLAG="INSTALL_RKE2_SKIP_RELOAD=true"
  ssh_cmd "curl -sfL https://get.rke2.io | $SKIP_RELOAD_FLAG INSTALL_RKE2_TYPE=agent sh -"

  log "writing /etc/rancher/rke2/config.yaml on $HOST_ALIAS..."
  # snapshotter: native - containerd's default overlayfs snapshotter can't
  # mount overlay-on-overlay, which is what happens when the host's own
  # rootfs is already overlayfs (true for both FakeNode* and the real
  # Kaggle_Zrok containers) - see note above.
  SNAPSHOTTER_LINE=""
  [[ "$CONTAINER_MODE" -eq 1 ]] && SNAPSHOTTER_LINE="snapshotter: native"
  ssh_cmd "mkdir -p /etc/rancher/rke2 && cat > /etc/rancher/rke2/config.yaml << EOF
server: $RKE2_URL
token: $NODE_TOKEN
$SNAPSHOTTER_LINE
EOF"

  if [[ "$CONTAINER_MODE" -eq 1 ]]; then
    log "remounting / as rshared on $HOST_ALIAS (needed for Cilium's mount-bpf-fs - same fix as the dev-harness entrypoint, but applied live here since we don't control how this VM's container was started)..."
    ssh_cmd "mount --make-rshared / 2>&1 || true"
    log "launching rke2 agent via screen session 'rke2_agent' on $HOST_ALIAS..."
    ssh_cmd "screen -S rke2_agent -dm /usr/local/bin/rke2 agent"
  else
    log "enabling + starting rke2-agent.service on $HOST_ALIAS..."
    ssh_cmd "systemctl enable rke2-agent.service && systemctl start rke2-agent.service"
  fi
fi

log "waiting for the node to register with the server (first run can take a few minutes)..."
for i in $(seq 1 60); do
  if kubectl get nodes 2>/dev/null | grep -qi "$HOST_ALIAS\|$(ssh_cmd 'hostname' 2>/dev/null)"; then
    log "node registered:"
    kubectl get nodes -o wide
    exit 0
  fi
  if [[ "$i" == "60" ]]; then
    log "ERROR: node did not register within 5 minutes."
    log "Check on $HOST_ALIAS: journalctl -u rke2-agent -f"
    log "Check connectivity: ssh $HOST_ALIAS \"curl -sk $RKE2_URL -o /dev/null -w '%{http_code}\\n'\" (expect a response, not connection-refused)"
    exit 1
  fi
  sleep 5
done
