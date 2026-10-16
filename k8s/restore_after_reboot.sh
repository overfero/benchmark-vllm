#!/usr/bin/env bash
# Run this after the laptop powers back on, to restore everything that does
# NOT survive a reboot on its own. RKE2/Docker/cluster state (etcd, pods,
# cached images) ARE systemd-managed and restore automatically - this script
# only recreates the tmux sessions that die with the laptop (zrok tunnels,
# the SSH port-forwards feeding the real vLLM backends + chat UI + Velero's
# S3 gateway into the cluster). FakeNode1 was permanently removed from the
# cluster (deleted Node object, container stopped) - it's not part of the
# architecture anymore, so there's nothing to restart for it here.
set -euo pipefail

echo "=== 0/4: fixing node-ip if the laptop's DHCP-assigned IP changed ==="
sudo bash "$(dirname "${BASH_SOURCE[0]}")/01-foundation/fix_node_ip.sh"

echo "=== 1/4: waiting for RKE2 apiserver ==="
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
until kubectl get nodes >/dev/null 2>&1; do sleep 3; done
kubectl get nodes

echo "=== 2/4: relaunching zrok tunnels (tmux sessions die on reboot) ==="
for pair in "Kaggle_Zrok7:akun7:qu6vrfw4jemj:9197" "Kaggle_Zrok8:akun8:8xpnonz7uv7g:9198" "Kaggle_Zrok9:akun9:fmcgyzep13v4:9199"; do
  IFS=: read -r session home share port <<< "$pair"
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "$session already running, skipping"
    continue
  fi
  tmux new-session -d -s "$session" \
    "env HOME=/home/overfero/.zrok-homes/$home zrok2 access private $share --bind 127.0.0.1:$port --headless; echo '[zrok exited rc=\$?]'; sleep 30"
  echo "relaunched $session"
done

echo "=== 3/4: relaunching SSH port-forwards (laptop -> real vLLM on Zrok7+8, rclone-S3 on Zrok7) ==="
sleep 5  # give the zrok tunnels above a moment to come up first
declare -A FORWARDS=(
  [vllm-tunnel-zrok7]="18001:localhost:8000 Kaggle_Zrok7"
  [vllm-tunnel-zrok8]="18000:localhost:8000 Kaggle_Zrok8"
  [vllm-tunnel-zrok9]="18002:localhost:8000 Kaggle_Zrok9"
  [velero-s3-tunnel]="19000:localhost:9000 Kaggle_Zrok7"
  [chat-ui-tunnel]="8080:localhost:8080 Kaggle_Zrok8"
)
for name in "${!FORWARDS[@]}"; do
  if tmux has-session -t "$name" 2>/dev/null; then
    echo "$name already running, skipping"
    continue
  fi
  read -r portspec host <<< "${FORWARDS[$name]}"
  tmux new-session -d -s "$name" "ssh -N -L 0.0.0.0:${portspec} ${host}"
  echo "relaunched $name"
done

echo "=== 4/4: verifying rclone-s3 gateway on Zrok7 (screen session on the VM itself, survives laptop reboot) ==="
timeout 10 ssh Kaggle_Zrok7 "screen -ls | grep -q rclone-s3" 2>/dev/null \
  && echo "rclone-s3 screen session still alive on Zrok7" \
  || echo "WARNING: rclone-s3 screen session missing on Zrok7 - relaunch manually (see Velero setup notes) if Velero backups are needed"

echo "=== Done. Verify with: ==="
echo "  tmux ls"
echo "  kubectl get pods -A | grep -v Running"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18000/health"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18001/health"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/"
