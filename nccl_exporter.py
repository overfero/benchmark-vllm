#!/usr/bin/env python3
"""Prometheus exporter for nccl-tests (/opt/nccl-tests/build/all_reduce_perf).

nccl-tests itself only produces a one-off CLI report, no continuous metrics
feed - this runs it periodically in a background thread and caches the last
result, exposing the real measured bandwidth (not a guess) as Prometheus
gauges. T4 has no NVLink (Turing, PCIe-only card - confirmed on NVIDIA's own
spec sheet), so this will always show PCIe-class bandwidth, never NVLink;
run with NCCL_DEBUG=INFO manually if you need the transport confirmed in
text form (see /root/nccl_debug.log written each cycle).
"""
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

BIN = "/opt/nccl-tests/build/all_reduce_perf"
RUN_EVERY_SECONDS = 300
TIMEOUT_SECONDS = 60

_lock = threading.Lock()
_latest = {"out_of_place_busbw_gbps": None, "in_place_busbw_gbps": None, "last_run_ts": 0, "ok": 0}

# Real example line from all_reduce_perf's own output table:
#   size(B) count type redop  root  time(us) algbw(GB/s) busbw(GB/s) ... time(us) algbw busbw ...
# Last row is the largest message size tested - most representative of
# sustained bandwidth, so that's what we keep.
ROW_RE = re.compile(r"^\s*\d+\s+\d+\s+\S+\s+\S+\s+-?\d+\s+[\d.]+\s+[\d.]+\s+([\d.]+)\s+\S+\s+[\d.]+\s+[\d.]+\s+([\d.]+)")


def run_once():
    try:
        env_log = open("/root/nccl_debug.log", "w")
        proc = subprocess.run(
            [BIN, "-b", "8", "-e", "256M", "-f", "2", "-g", "2"],
            capture_output=True, text=True, timeout=TIMEOUT_SECONDS,
            env={"NCCL_DEBUG": "INFO", "PATH": "/usr/local/cuda/bin:/usr/bin:/bin"},
        )
        env_log.write(proc.stdout + proc.stderr)
        env_log.close()
        last_inplace_busbw = None
        last_oop_busbw = None
        for line in proc.stdout.splitlines():
            m = ROW_RE.match(line)
            if m:
                last_oop_busbw = float(m.group(1))
                last_inplace_busbw = float(m.group(2))
        with _lock:
            if last_oop_busbw is not None:
                _latest["out_of_place_busbw_gbps"] = last_oop_busbw
                _latest["in_place_busbw_gbps"] = last_inplace_busbw
                _latest["ok"] = 1
            else:
                _latest["ok"] = 0
            _latest["last_run_ts"] = time.time()
    except Exception:
        with _lock:
            _latest["ok"] = 0
            _latest["last_run_ts"] = time.time()


def background_loop():
    while True:
        run_once()
        time.sleep(RUN_EVERY_SECONDS)


def collect() -> str:
    with _lock:
        snap = dict(_latest)
    lines = ["# HELP nccl_allreduce_* all_reduce_perf bandwidth, largest message size tested (PCIe on T4 - no NVLink)"]
    lines.append(f"nccl_allreduce_last_run_ok {snap['ok']}")
    lines.append(f"nccl_allreduce_last_run_timestamp_seconds {snap['last_run_ts']}")
    if snap["out_of_place_busbw_gbps"] is not None:
        lines.append(f"nccl_allreduce_out_of_place_busbw_gbps {snap['out_of_place_busbw_gbps']}")
        lines.append(f"nccl_allreduce_in_place_busbw_gbps {snap['in_place_busbw_gbps']}")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = collect().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=background_loop, daemon=True).start()
    server = HTTPServer(("0.0.0.0", 9401), Handler)
    print("nccl_exporter listening on :9401/metrics (first run may take up to 60s)")
    server.serve_forever()
