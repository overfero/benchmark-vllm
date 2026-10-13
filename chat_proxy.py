#!/usr/bin/env python3
"""Serves chat_dashboard.html at / and reverse-proxies /v1/* + /health to
the real vLLM server on localhost:8000, streaming SSE through untouched.
The dashboard's own JS expects same-origin (API_BASE = "") so this exists
purely to avoid a cross-origin fetch from the browser to a different port.
"""
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, StreamingResponse

VLLM_BASE = "http://localhost:8000"
HTML_PATH = "/root/chat_dashboard.html"

app = FastAPI()
client = httpx.AsyncClient(base_url=VLLM_BASE, timeout=None)


@app.get("/")
async def index():
    return FileResponse(HTML_PATH)


@app.api_route("/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request):
    body = await request.body()
    upstream_req = client.build_request(
        request.method, f"/{path}", content=body,
        headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
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
