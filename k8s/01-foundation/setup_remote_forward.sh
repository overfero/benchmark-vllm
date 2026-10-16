#!/usr/bin/env bash
# Adds the SSH RemoteForward entries needed for RKE2 agents on
# Kaggle_Zrok7/Kaggle_Zrok8 to reach the RKE2 server running on this laptop.
#
# Why this is needed: the laptop can SSH out to the Zrok VMs, but the Zrok
# VMs cannot reach the laptop directly (that's the whole reason the zrok
# tunnel exists in the first place). RKE2 agents need to reach the
# server's supervisor API on :9345 to join and stay connected, and `kubectl`
# run FROM a Zrok VM (if ever needed) would need :6443. A RemoteForward
# makes 127.0.0.1:<port> ON THE REMOTE VM tunnel back to 127.0.0.1:<port>
# ON THE LAPTOP - exactly the right direction, and this project's
# ~/.ssh/config already uses this same mechanism (RemoteForward 20128) for
# a different purpose, so this just adds two more forwards to the same
# existing Host blocks rather than inventing a new mechanism.
#
# IMPORTANT: a RemoteForward only takes effect for SSH sessions established
# AFTER the config change - it does not retroactively apply to an
# already-open session. After running this, any existing persistent `ssh`
# session to Kaggle_Zrok7/Kaggle_Zrok8 must be reconnected for the forward
# to actually be live.
#
# Usage: ./setup_remote_forward.sh

set -euo pipefail

SSH_CONFIG="$HOME/.ssh/config"
PORTS=(9345 6443)

log() { echo "[setup-remote-forward] $*" >&2; }

[[ -f "$SSH_CONFIG" ]] || { echo "FATAL: $SSH_CONFIG not found" >&2; exit 1; }

for host in Kaggle_Zrok7 Kaggle_Zrok8; do
  if ! grep -q "^Host $host\$" "$SSH_CONFIG"; then
    log "WARNING: no 'Host $host' block found in $SSH_CONFIG - skipping (expected this to already exist)"
    continue
  fi

  for port in "${PORTS[@]}"; do
    # Idempotent: check if this exact RemoteForward line already exists
    # WITHIN this host's block (not just anywhere in the file) before
    # appending - python here does the block-scoped insert precisely,
    # since a plain grep -q "RemoteForward $port" could match a
    # different Host block entirely.
    python3 - "$SSH_CONFIG" "$host" "$port" << 'PYEOF'
import re, sys
path, host, port = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()

pattern = re.compile(rf"(Host {host}\n(?:  .*\n)*)")
m = pattern.search(text)
if not m:
    sys.exit(0)
block = m.group(1)
line = f"  RemoteForward {port} 127.0.0.1:{port}\n"
if f"RemoteForward {port} " in block:
    print(f"already present for {host}:{port}")
    sys.exit(0)
new_block = block.rstrip("\n") + "\n" + line
text = text[:m.start()] + new_block + text[m.end():]
open(path, "w").write(text)
print(f"added for {host}:{port}")
PYEOF
  done
done

log "done. RECONNECT any existing persistent SSH sessions to Kaggle_Zrok7/Kaggle_Zrok8"
log "for the new RemoteForward to actually take effect (it only applies to"
log "sessions established after this config change)."
log ""
log "Verify after reconnecting with, e.g.:"
log "  ssh Kaggle_Zrok7 'curl -sk https://127.0.0.1:9345 -o /dev/null -w \"%{http_code}\\n\"'"
log "(expect a TLS/HTTP response, not connection-refused, once the RKE2 server is actually running)"
