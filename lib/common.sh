#!/usr/bin/env bash
# Shared helpers for every script in this repo: ssh_cmd (retrying ssh
# wrapper), log(), and the common CLI arg parsing (--api-key/--host-alias).
# Source this, don't execute it directly:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# Everything here is captured from a REAL, validated run against the
# Kaggle_Zrok7/Kaggle_Zrok8 2xT4 hosts, not a guess - see each comment for the
# real failure it fixes.

HOST_ALIAS="${HOST_ALIAS:-Kaggle_Zrok8}"
API_KEY="${API_KEY:-}"
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}")"

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --api-key) API_KEY="$2"; shift 2 ;;
      --host-alias) HOST_ALIAS="$2"; shift 2 ;;
      -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
  done
}

log() { echo "[$SCRIPT_NAME] $*" >&2; }

# Retries on a TRANSPORT failure (ssh exit 255 - tunnel drop, connection
# refused/reset) up to 3x with a short backoff, since this zrok tunnel is
# known-flaky and a transient drop during a check must not be misread as "the
# thing being checked doesn't exist" (ssh's own exit 255 looks identical to a
# real remote command failure otherwise, which caused a real false "vLLM not
# installed, reinstalling" -> reinstall itself also hit the dead tunnel ->
# misleading "FATAL: vLLM install failed" when vLLM was actually fine).
ssh_cmd() {
  local attempt out rc
  for attempt in 1 2 3; do
    # -o LogLevel=ERROR: this project's ~/.ssh/config sets UserKnownHostsFile
    # /dev/null for every Kaggle_Zrok* host, so WITHOUT this flag every ssh
    # call re-prints "Warning: Permanently added ... to the list of known
    # hosts" to stderr - and since this function merges stderr into the
    # captured output below, that banner silently corrupts every variable
    # captured via $(ssh_cmd ...). Real bug hit this session, confirmed via
    # side-by-side comparison with/without the flag.
    out=$(ssh -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 "$HOST_ALIAS" "$@" 2>&1)
    rc=$?
    if [[ $rc -ne 255 ]]; then
      echo "$out"
      return $rc
    fi
    echo "$out" >&2
    log "ssh transport failure (attempt $attempt/3) - tunnel likely dropped, retrying in 5s..."
    sleep 5
  done
  log "ssh transport failed 3x in a row - tunnel is down, not just flaky. Giving up on this call."
  return 255
}

scp_cmd() {
  scp -q -o LogLevel=ERROR "$@"
}

# Run-lock: refuse to start a second instance of a script against the SAME
# host while one is already running. Real bug hit this session: two
# overlapping invocations (one left over from an earlier attempt whose SSH
# client had died but whose remote command survived) both ran `uv pip install
# guidellm locust` against the same conda env at once and deadlocked each
# other indefinitely (confirmed via /proc: both sleeping, neither making
# progress, for over an hour). Keyed by script name + host so independent
# per-service scripts can run in parallel against the same host without
# stepping on each other, while two runs of the SAME script against the SAME
# host still get serialized.
acquire_lock() {
  local lock_file="/tmp/benchmark_vllm_${SCRIPT_NAME}_${HOST_ALIAS}.lock"
  exec 200>"$lock_file"
  flock -n 200 || {
    echo "FATAL: another instance of $SCRIPT_NAME is already running against $HOST_ALIAS (lock: $lock_file)." >&2
    exit 1
  }
}
