#!/usr/bin/env python3
"""Serves chat_dashboard.html at / and reverse-proxies /v1/* + /health to
the real vLLM server on localhost:8000, streaming SSE through untouched.
The dashboard's own JS expects same-origin (API_BASE = "") so this exists
purely to avoid a cross-origin fetch from the browser to a different port.
"""
import os

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, StreamingResponse

# Defaults match the original bare-metal deployment (chat_proxy.py running
# directly on the same VM as vLLM, talking to it over localhost) -
# overridable so the same image/script can instead point at LiteLLM (gets
# PII masking + content safety + audit logging in front of the model,
# instead of hitting vLLM directly) without touching this file again.
UPSTREAM_BASE = os.environ.get("CHAT_PROXY_UPSTREAM_BASE", "http://localhost:8000")
HTML_PATH = "/root/chat_dashboard.html"
# The dashboard's own JS never sends auth (same-origin, no login UI) -
# injected server-side instead so the key/token never reaches the browser.
UPSTREAM_API_KEY = os.environ.get("CHAT_PROXY_API_KEY", os.environ.get("VLLM_API_KEY", ""))

app = FastAPI()
client = httpx.AsyncClient(base_url=UPSTREAM_BASE, timeout=None)


@app.get("/")
async def index():
    return FileResponse(HTML_PATH)


@app.api_route("/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request):
    body = await request.body()
    headers = {k: v for k, v in request.headers.items() if k.lower() != "host"}
    if UPSTREAM_API_KEY:
        headers["authorization"] = f"Bearer {UPSTREAM_API_KEY}"
    upstream_req = client.build_request(
        request.method, f"/{path}", content=body, headers=headers,
    )
    upstream_resp = await client.send(upstream_req, stream=True)

    async def stream():
        async for chunk in upstream_resp.aiter_raw():
            yield chunk
        await upstream_resp.aclose()

    return StreamingResponse(
        stream(),
        status_code=upstream_resp.status_code,
        media_type=upstream_resp.headers.get("content-type"),
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
