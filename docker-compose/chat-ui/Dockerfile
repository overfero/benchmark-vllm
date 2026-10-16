# Containerizes the already-proven-working chat_proxy.py + chat_dashboard.html
# (the bare-metal version running on Zrok8 this session, same files - see
# ../../chat_proxy.py / ../../chat_dashboard.html). fastapi/httpx/uvicorn
# were previously reused from vLLM's own conda env; here they're installed
# directly since there's no vLLM env to borrow from in this standalone image.
# WORKDIR is /root (not /app) to match chat_proxy.py's own hardcoded
# HTML_PATH = "/root/chat_dashboard.html" - avoids touching the already-
# proven-working script just to fit a different directory convention.
FROM python:3.12-slim
WORKDIR /root
RUN pip install --no-cache-dir fastapi httpx 'uvicorn[standard]'
COPY chat_dashboard.html chat_proxy.py ./
EXPOSE 8080
CMD ["python", "chat_proxy.py"]
