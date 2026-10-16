#!/usr/bin/env bash
# Tears down the fake-vm dev/test containers and removes their SSH config
# blocks. Use this once a node-bring-up script has been validated against
# FakeNodeN and you're moving on to the real Kaggle_Zrok7/Kaggle_Zrok8 run -
# no need to keep the fake nodes running.
#
# Usage: ./down.sh [count]   (default count: 1, must match what up.sh used)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

COUNT="${1:-1}"
SSH_CONFIG="$HOME/.ssh/config"

for i in $(seq 1 "$COUNT"); do
  name="fake-vm-$i"
  alias="FakeNode$i"

  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo "[dev-harness] removing $name..."
    docker rm -f "$name" >/dev/null
  else
    echo "[dev-harness] $name not running, skipping"
  fi

  if grep -q "^Host $alias\$" "$SSH_CONFIG" 2>/dev/null; then
    echo "[dev-harness] removing $alias block from $SSH_CONFIG..."
    python3 - "$SSH_CONFIG" "$alias" << 'PYEOF'
import re, sys
path, alias = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(rf"\n?Host {alias}\n(?:  .*\n)*", "\n", text)
open(path, "w").write(text)
PYEOF
  fi
done

echo "[dev-harness] done."
