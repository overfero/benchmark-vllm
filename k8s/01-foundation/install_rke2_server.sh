#!/usr/bin/env bash
# Installs RKE2 SERVER (control plane) directly on THIS laptop - bare
# metal, systemd service, no Docker/VM wrapper. This is intentional per
# the plan: the laptop's own GPU is too weak (NVIDIA MX350, 2GB VRAM) for
# real serving, but the control plane itself needs no GPU at all - the
# real GPU capacity lives on the Kaggle_Zrok7/Kaggle_Zrok8 agent nodes
# (joined separately via join_rke2_agent.sh).
#
# This IS a real, visible change to the laptop's own OS: a new
# rke2-server.service, CNI/iptables rules, /etc/rancher/rke2/. Rollback:
# RKE2 ships an official /usr/local/bin/rke2-uninstall.sh for exactly this.
#
# cni=cilium is set at install time (not canal, RKE2's default) since
# Cilium is this stack's chosen CNI - it gets actually installed via Helm
# in a later step, this just tells RKE2 not to bring up its own default
# canal manifests that would conflict with it.
#
# Usage: sudo ./install_rke2_server.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "FATAL: must run as root (sudo) - installs a systemd service and writes /etc/rancher" >&2
  exit 1
fi

log() { echo "[install-rke2-server] $*" >&2; }

if systemctl is-active --quiet rke2-server 2>/dev/null; then
  log "rke2-server already running, skipping install"
else
  log "downloading + running RKE2's official install script (server channel)..."
  curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -

  log "writing /etc/rancher/rke2/config.yaml (cilium CNI, disable bundled ingress-nginx)..."
  mkdir -p /etc/rancher/rke2
  cat > /etc/rancher/rke2/config.yaml << 'EOF'
cni: cilium
disable:
  - rke2-ingress-nginx
  - rke2-traefik
write-kubeconfig-mode: "0644"
EOF

  log "enabling + starting rke2-server.service..."
  systemctl enable rke2-server.service
  systemctl start rke2-server.service
fi

log "waiting for node to register (this can take a few minutes - first real run, not a hang)..."
export PATH="$PATH:/var/lib/rancher/rke2/bin"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
for i in $(seq 1 60); do
  if kubectl get nodes >/dev/null 2>&1; then
    log "server node registered:"
    kubectl get nodes -o wide
    break
  fi
  [[ "$i" == "60" ]] && { log "ERROR: node did not register within 5 minutes - check 'journalctl -u rke2-server -f'"; exit 1; }
  sleep 5
done

log ""
log "=== RKE2 server up ==="
log "kubeconfig: /etc/rancher/rke2/rke2.yaml (mode 0644, readable without sudo)"
log "kubectl path: /var/lib/rancher/rke2/bin/kubectl (or: export PATH=\$PATH:/var/lib/rancher/rke2/bin)"
log "node-token (needed by join_rke2_agent.sh): /var/lib/rancher/rke2/server/node-token"
log "supervisor API port for agents to join: 9345 (needs the SSH RemoteForward from setup_remote_forward.sh to reach it from Kaggle_Zrok7/8)"
