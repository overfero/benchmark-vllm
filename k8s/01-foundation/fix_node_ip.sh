#!/usr/bin/env bash
# This laptop's WiFi-assigned IP changes across reboots/reconnects (DHCP),
# but RKE2's single-node etcd has THREE separate places that remember the
# old IP and don't auto-update: /etc/rancher/rke2/config.yaml (node-ip),
# etcd's own static config at /var/lib/rancher/rke2/server/db/etcd/config
# (listen/advertise peer URLs), and etcd's internal membership record
# (persisted inside etcd's own data, only fixable via --cluster-reset).
# Missing any ONE of these three leaves etcd crash-looping - confirmed the
# hard way this session (each layer surfaced as a separate, different-
# looking error only after fixing the one before it). This script fixes
# all three in the right order, in one shot, run with sudo.
#
# Usage: sudo bash fix_node_ip.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (sudo bash fix_node_ip.sh)" >&2
  exit 1
fi

CONFIG_YAML=/etc/rancher/rke2/config.yaml
ETCD_CONFIG=/var/lib/rancher/rke2/server/db/etcd/config

# The real local WiFi/LAN IP - excludes loopback, docker/cilium/lxc bridges,
# and tailscale (those are virtual interfaces, not what RKE2 should bind to).
NEW_IP=$(ip -4 addr show wlp2s0 2>/dev/null | grep -oP 'inet \K[\d.]+' || true)
if [[ -z "$NEW_IP" ]]; then
  echo "could not auto-detect WiFi IP on wlp2s0 - check 'ip -4 addr' manually and edit this script's interface name if it changed" >&2
  exit 1
fi

OLD_IP=$(grep -oP 'node-ip: "\K[\d.]+' "$CONFIG_YAML" || true)
if [[ -z "$OLD_IP" ]]; then
  echo "could not read current node-ip from $CONFIG_YAML" >&2
  exit 1
fi

if [[ "$OLD_IP" == "$NEW_IP" ]]; then
  echo "node-ip already matches current IP ($NEW_IP) - nothing to fix, no reset needed"
  exit 0
fi

echo "fixing node-ip: $OLD_IP -> $NEW_IP"

echo "1/4: stopping rke2-server"
systemctl stop rke2-server

echo "2/4: updating $CONFIG_YAML"
sed -i "s/node-ip: \"$OLD_IP\"/node-ip: \"$NEW_IP\"/" "$CONFIG_YAML"

if [[ -f "$ETCD_CONFIG" ]]; then
  echo "3/4: updating $ETCD_CONFIG"
  sed -i "s/$OLD_IP/$NEW_IP/g" "$ETCD_CONFIG"
else
  echo "3/4: $ETCD_CONFIG not present yet, skipping (fresh install)"
fi

echo "4/5: resetting etcd membership record (stale entry for $OLD_IP) and starting"
/usr/local/bin/rke2 server --cluster-reset
systemctl start rke2-server

echo "5/5: waiting for apiserver, then patching the vllm-zrok7/8-external Endpoints (same stale-IP problem, different layer - these point the cluster at the SSH tunnels on THIS laptop's IP, confirmed to go stale and silently break LiteLLM once already)"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
for i in $(seq 1 60); do kubectl get nodes >/dev/null 2>&1 && break; sleep 3; done
for ns_svc in "default:vllm-zrok7-external" "default:vllm-zrok8-external" "default:vllm-zrok9-external" "litellm:chat-ui-external"; do
  ns="${ns_svc%%:*}"; svc="${ns_svc##*:}"
  if kubectl get endpoints "$svc" -n "$ns" >/dev/null 2>&1; then
    kubectl patch endpoints "$svc" -n "$ns" --type='json' \
      -p="[{\"op\":\"replace\",\"path\":\"/subsets/0/addresses/0/ip\",\"value\":\"$NEW_IP\"}]" \
      && echo "patched $ns/$svc -> $NEW_IP"
  fi
done

echo "done - run 'kubectl get nodes' to confirm the apiserver is back, and verify the SSH tunnels (vllm-tunnel-zrok7/8) are also up on the new IP"
