#!/usr/bin/env bash
# Builds the fake-vm image and runs N containers that mimic a FRESH
# Kaggle_Zrok VM (bare Ubuntu + sshd + systemd, no pre-existing state),
# then registers them in ~/.ssh/config as FakeNode1..N so lib/common.sh's
# ssh_cmd works against them exactly like it does against the real
# Kaggle_Zrok7/Kaggle_Zrok8 hosts. Use these to smoke-test node-bring-up
# scripts (join_rke2_agent.sh etc.) BEFORE running them against the real,
# quota-limited, flaky Zrok VMs - never run untested scripts there first.
#
# Usage: ./up.sh [count]   (default count: 1)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COUNT="${1:-1}"
IMAGE="benchmark-vllm/fake-vm:latest"
SSH_CONFIG="$HOME/.ssh/config"
BASE_PORT=12200  # arbitrary, unused range - avoids clashing with real Kaggle_Zrok* ports (9197/9198) or anything else local

echo "[dev-harness] building $IMAGE..."
docker build -q -t "$IMAGE" -f Dockerfile.fake-vm . >/dev/null

for i in $(seq 1 "$COUNT"); do
  name="fake-vm-$i"
  port=$((BASE_PORT + i))
  alias="FakeNode$i"

  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo "[dev-harness] $name already exists - removing stale container first"
    docker rm -f "$name" >/dev/null
  fi

  echo "[dev-harness] starting $name (ssh on localhost:$port, alias $alias)..."
  docker run -d --name "$name" --privileged \
    -p "127.0.0.1:$port:22" \
    "$IMAGE" >/dev/null

  # Idempotent: remove any stale block for this alias before appending a
  # fresh one, so re-running up.sh after down.sh (new container, same
  # alias, likely different host key if ever using StrictHostKeyChecking)
  # doesn't leave duplicate/conflicting Host blocks.
  if grep -q "^Host $alias\$" "$SSH_CONFIG" 2>/dev/null; then
    python3 - "$SSH_CONFIG" "$alias" << 'PYEOF'
import re, sys
path, alias = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(rf"Host {alias}\n(?:  .*\n)*", "", text)
open(path, "w").write(text)
PYEOF
  fi

  cat >> "$SSH_CONFIG" << EOF

Host $alias
  HostName 127.0.0.1
  Port $port
  User root
  IdentityFile ~/.ssh/kaggle_rsa
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
EOF

  echo "[dev-harness] waiting for sshd in $name..."
  for attempt in $(seq 1 15); do
    if ssh -o LogLevel=ERROR -o ConnectTimeout=3 -o BatchMode=yes "$alias" "echo ok" >/dev/null 2>&1; then
      echo "[dev-harness] $alias is up"
      break
    fi
    [[ "$attempt" == 15 ]] && { echo "[dev-harness] WARNING: $alias did not come up in time - check 'docker logs $name'" >&2; }
    sleep 2
  done
done

echo "[dev-harness] done. SSH host aliases ready: $(seq 1 "$COUNT" | sed 's/^/FakeNode/' | tr '\n' ' ')"
