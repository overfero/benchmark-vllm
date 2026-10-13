#!/usr/bin/env bash
# Downloads (if needed) Grafana, (re)launches it in a remote screen session
# ('grafana', :3000), then auto-provisions the Prometheus datasource and
# pushes both dashboards (grafana_gpu_dashboard.json, grafana_bench_dashboard.json).
#
# Idempotent datasource creation: Grafana itself rejects a duplicate name,
# so this just finds the existing one's UID instead of erroring. Default
# login is admin/admin on a fresh install; if a prior session already
# changed it, the provisioning curl's 401 fails loudly rather than silently
# skipping (better to notice than to think the dashboards are there when
# they're not).
#
# Usage: ./service_grafana.sh --host-alias Kaggle_Zrok8 [--port 3000] [--prometheus-port 9090]

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source lib/common.sh

GRAFANA_PORT=3000
PROM_PORT=9090

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-alias) HOST_ALIAS="$2"; shift 2 ;;
    --port) GRAFANA_PORT="$2"; shift 2 ;;
    --prometheus-port) PROM_PORT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

acquire_lock

binaries_ok() {
  ssh_cmd "/opt/monitoring/grafana-v11.4.0/bin/grafana --version >/dev/null 2>&1"
}
log "checking Grafana binary on $HOST_ALIAS..."
if ! binaries_ok; then
  log "downloading Grafana binary..."
  ssh_cmd "mkdir -p /opt/monitoring && cd /opt/monitoring && rm -rf grafana-v11.4.0 grafana.tar.gz && \
    curl -sL https://dl.grafana.com/oss/release/grafana-11.4.0.linux-amd64.tar.gz -o grafana.tar.gz && tar xzf grafana.tar.gz"
  binaries_ok || {
    echo "FATAL: Grafana binary still broken after re-download (check network/disk on $HOST_ALIAS)" >&2
    exit 1
  }
fi

log "stopping any existing grafana screen/process..."
ssh_cmd "screen -S grafana -X quit 2>/dev/null; pkill -f 'bin/grafana server' 2>/dev/null; true"
sleep 2

log "launching Grafana (screen 'grafana', :$GRAFANA_PORT)..."
ssh_cmd "mkdir -p /opt/monitoring/grafana_data && cd /opt/monitoring/grafana-v11.4.0 && \
  screen -S grafana -dm ./bin/grafana server --homepath . --config conf/defaults.ini cfg:default.paths.data=/opt/monitoring/grafana_data cfg:default.server.http_port=$GRAFANA_PORT"

log "waiting for Grafana to come up..."
for i in $(seq 1 15); do
  code=$(ssh_cmd "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$GRAFANA_PORT/api/health" || true)
  [[ "$code" == "200" ]] && break
  sleep 2
done
log "Grafana health check: HTTP $code"

log "provisioning Grafana datasource + dashboards..."
ds_create=$(ssh_cmd "curl -s -u admin:admin -X POST -H 'Content-Type: application/json' -d '{\"name\":\"Prometheus\",\"type\":\"prometheus\",\"url\":\"http://localhost:$PROM_PORT\",\"access\":\"proxy\",\"isDefault\":true}' http://localhost:$GRAFANA_PORT/api/datasources")
if grep -q '"uid"' <<<"$ds_create"; then
  DS_UID=$(grep -o '"uid":"[^"]*"' <<<"$ds_create" | head -1 | cut -d'"' -f4)
else
  DS_UID=$(ssh_cmd "curl -s -u admin:admin http://localhost:$GRAFANA_PORT/api/datasources" | grep -o '"uid":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
if [[ -z "$DS_UID" ]]; then
  log "WARNING: could not determine Grafana datasource UID - skipping dashboard provisioning (check admin credentials on $HOST_ALIAS)"
  exit 1
fi
log "Grafana datasource UID: $DS_UID"
for dash in grafana_gpu_dashboard grafana_bench_dashboard; do
  sed "s/PROM_DS_UID/$DS_UID/g" "$dash.json" > "/tmp/${dash}_${HOST_ALIAS}.json"
  scp_cmd "/tmp/${dash}_${HOST_ALIAS}.json" "$HOST_ALIAS:/tmp/$dash.json"
  result=$(ssh_cmd "curl -s -u admin:admin -X POST -H 'Content-Type: application/json' -d @/tmp/$dash.json http://localhost:$GRAFANA_PORT/api/dashboards/db")
  if grep -q '"status":"success"' <<<"$result"; then
    log "pushed $dash OK"
  else
    log "WARNING: pushing $dash may have failed: $result"
  fi
done
