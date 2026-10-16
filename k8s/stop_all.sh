#!/usr/bin/env bash
# Turns everything off to free up this laptop's RAM/CPU. Pairs with
# restore_after_reboot.sh (the "turn on" script) - run that one to bring
# everything back exactly where it left off (etcd/k8s state persists on
# disk regardless of rke2-server being stopped, so nothing is lost).
#
# Usage: bash stop_all.sh
set -euo pipefail

echo "=== 1/2: killing local SSH tunnels (tmux sessions) ==="
for name in Kaggle_Zrok7 Kaggle_Zrok8 Kaggle_Zrok9 chat-ui-tunnel velero-s3-tunnel \
            vllm-tunnel-zrok7 vllm-tunnel-zrok8 vllm-tunnel-zrok9; do
  if tmux has-session -t "$name" 2>/dev/null; then
    tmux kill-session -t "$name"
    echo "killed $name"
  fi
done

echo "=== 2/2: stopping rke2-server (needs sudo - stops etcd, apiserver, all pods) ==="
sudo systemctl stop rke2-server

echo "done - laptop should be noticeably lighter now."
echo "to bring everything back: bash $(dirname "${BASH_SOURCE[0]}")/restore_after_reboot.sh"
