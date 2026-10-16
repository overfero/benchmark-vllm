#!/bin/bash
# Remounts / as rshared before handing off to systemd - without this,
# Cilium's mount-bpf-fs init container fails with "/sys/fs/bpf is mounted
# on /sys but it is not a shared mount" (Docker's default mount
# propagation is private). Same pattern kind/k3d use for nested K8s.
set -e
mount --make-rshared / 2>&1 || true
exec "$@"
