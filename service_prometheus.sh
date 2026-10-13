#!/usr/bin/env bash
# Downloads (if needed) Prometheus and (re)launches it in a remote screen
# session ('prometheus'), on :9090.
#
# Real fix baked in: checks the binary is actually EXECUTABLE AND RUNNABLE
# (`--version`), not just present - the Prometheus tarball download got
# truncated by a flaky tunnel partway through once (curl -sL reported
# success, tar extracted whatever partial bytes it received, leaving a
# directory with just LICENSE/NOTICE and no `prometheus` binary at all), and
# a plain `[[ -x ... ]]` check would have called that "already built" on a
# retry and skipped straight past it. Re-download if the binary is missing
# OR present-but-broken.
#
# Usage: ./service_prometheus.sh --host-alias Kaggle_Zrok8 [--port 9090]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

PROM_PORT=9090

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --port) PROM_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

acquire_lock

binaries_ok() {
  ssh_cmd "/opt/monitoring/prometheus-3.0.1.linux-amd64/prometheus --version >/dev/null 2>&1"
}
log "checking Prometheus binary on $HOST_ALIAS..."
if ! binaries_ok; then
  log "downloading Prometheus binary..."
  ssh_cmd "mkdir -p /opt/monitoring && cd /opt/monitoring && rm -rf prometheus-3.0.1.linux-amd64 prom.tar.gz && \
    curl -sL https://github.com/prometheus/prometheus/releases/download/v3.0.1/prometheus-3.0.1.linux-amd64.tar.gz -o prom.tar.gz && tar xzf prom.tar.gz"
  binaries_ok || {
    echo "FATAL: Prometheus binary still broken after re-download (check network/disk on $HOST_ALIAS)" >&2
    exit 1
  }
fi

scp_cmd prometheus.yml "$HOST_ALIAS:/opt/monitoring/prometheus.yml"

log "stopping any existing prometheus screen/process (kills by process name too - an orphan can run OUTSIDE any screen session if it was launched manually before, which 'screen -X quit' can never reach)..."
ssh_cmd "screen -S prometheus -X quit 2>/dev/null; pkill -f '/prometheus --config' 2>/dev/null; true"
sleep 2

log "launching Prometheus (screen 'prometheus', :$PROM_PORT)..."
ssh_cmd "cd /opt/monitoring/prometheus-3.0.1.linux-amd64 && screen -S prometheus -dm ./prometheus --config.file=/opt/monitoring/prometheus.yml --storage.tsdb.path=/opt/monitoring/prom_data --web.listen-address=0.0.0.0:$PROM_PORT"

sleep 2
code=$(ssh_cmd "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PROM_PORT/-/healthy" || true)
log "Prometheus health check: HTTP $code"
