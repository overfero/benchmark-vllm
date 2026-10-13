#!/usr/bin/env python3
"""Lightweight Prometheus exporter backed by REAL DCGM (via `dcgmi dmon`),
not nvidia-smi. Stand-in for dcgm-exporter (Docker-only distribution, no
standalone binary) in a Docker-less environment - but the actual data
source is now genuine DCGM (nv-hostengine), not nvidia-smi, once the NVML
library version-mismatch (stale /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1
vs the real driver's /usr/local/nvidia/lib64 one) was fixed.

Falls back to nvidia-smi only if dcgmi itself is unreachable, so the
exporter degrades gracefully instead of going dark.
"""
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

# DCGM field IDs that are confirmed working on this host, verified via a
# real `dcgmi dmon` run, not guessed from field-ID tables. Profiling module
# fields (GRACT/SM-occupancy etc.) fail to load here - a separate, common
# limitation needing extra perf-counter permissions - so those are excluded.
# pcie_tx_throughput/pcie_rx_throughput (200/201) were tried and come back
# N/A on this hardware/driver combo - also excluded, not included-but-fake.
DCGM_FIELDS = {
    "150": "temperature_celsius",
    "155": "power_draw_watts",
    "203": "utilization_gpu_percent",
    "252": "memory_used_mib",
    "254": "memory_free_mib",
    "100": "sm_clock_mhz",
    "101": "memory_clock_mhz",
    "237": "pcie_link_gen",
    "238": "pcie_link_width",
    "240": "power_violation",
    "241": "thermal_violation",
}
FIELD_IDS = ",".join(DCGM_FIELDS.keys())


def collect_dcgm() -> str | None:
    try:
        out = subprocess.run(
            ["dcgmi", "dmon", "-e", FIELD_IDS, "-c", "1"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except Exception:
        return None

    lines = out.strip().splitlines()
    # Header lines start with '#' or 'ID' - data lines start with "GPU <n>"
    data_lines = [l for l in lines if l.strip().startswith("GPU ")]
    if not data_lines:
        return None

    metric_names = list(DCGM_FIELDS.values())
    out_lines = ["# HELP dcgm_gpu_* GPU metrics from real DCGM (dcgmi dmon)"]
    for row in data_lines:
        parts = row.split()
        gpu_id = parts[1]
        values = parts[2:2 + len(metric_names)]
        for name, val in zip(metric_names, values):
            out_lines.append(f'dcgm_gpu_{name}{{gpu="{gpu_id}"}} {val}')
    return "\n".join(out_lines) + "\n"


def collect_nvidia_smi_fallback() -> str:
    fields = [
        "index", "utilization.gpu", "memory.used", "memory.free", "temperature.gpu", "power.draw",
        "clocks.sm", "clocks.mem", "pcie.link.gen.current", "pcie.link.width.current",
    ]
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--query-gpu={','.join(fields)}", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except Exception as e:
        return f"# gpu_exporter_error 1\n# {e}\n"

    lines = ["# HELP dcgm_gpu_* FALLBACK: nvidia-smi (dcgmi unreachable)"]
    for row in out.strip().splitlines():
        idx, util, mem_used, mem_free, temp, pwr, sm_clk, mem_clk, pcie_gen, pcie_width = [v.strip() for v in row.split(",")]
        labels = f'{{gpu="{idx}"}}'
        lines += [
            f"dcgm_gpu_utilization_gpu_percent{labels} {util}",
            f"dcgm_gpu_memory_used_mib{labels} {mem_used}",
            f"dcgm_gpu_memory_free_mib{labels} {mem_free}",
            f"dcgm_gpu_temperature_celsius{labels} {temp}",
            f"dcgm_gpu_power_draw_watts{labels} {pwr}",
            f"dcgm_gpu_sm_clock_mhz{labels} {sm_clk}",
            f"dcgm_gpu_memory_clock_mhz{labels} {mem_clk}",
            f"dcgm_gpu_pcie_link_gen{labels} {pcie_gen}",
            f"dcgm_gpu_pcie_link_width{labels} {pcie_width}",
        ]
    return "\n".join(lines) + "\n"


def collect() -> str:
    dcgm_result = collect_dcgm()
    return dcgm_result if dcgm_result is not None else collect_nvidia_smi_fallback()


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
    server = HTTPServer(("0.0.0.0", 9400), Handler)
    print("gpu_exporter (DCGM-backed) listening on :9400/metrics")
    server.serve_forever()
