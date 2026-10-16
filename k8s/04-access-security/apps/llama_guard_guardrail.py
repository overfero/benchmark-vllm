# Custom LiteLLM guardrail wrapping our own Llama-Guard-3-8B-AWQ (served by
# vLLM on Kaggle_Zrok9, bridged in as vllm-zrok9-external - see
# vllm-external-backend.yaml). LiteLLM has no built-in "llama_guard"
# provider (confirmed via its own docs - only a legacy SageMaker-only
# `llamaguard_moderations` callback exists, not applicable to a self-hosted
# OpenAI-compatible endpoint), so this follows LiteLLM's documented Custom
# Guardrail interface instead: https://docs.litellm.ai/docs/proxy/guardrails/custom_guardrail
#
# Llama Guard's own chat template classifies the LAST user turn and replies
# with either "safe" or "unsafe\n<category>" - async_moderation_hook (the
# during_call hook) is the right fit since it can only block, never modify,
# which matches exactly what a safe/unsafe classifier should do.
import os

import httpx

from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.proxy._types import UserAPIKeyAuth


class LlamaGuardGuardrail(CustomGuardrail):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.api_base = os.environ.get(
            "LLAMA_GUARD_API_BASE",
            "http://vllm-zrok9-external.default.svc.cluster.local:8000/v1",
        )
        self.api_key = os.environ.get("LLAMA_GUARD_API_KEY", "")
        self.model = os.environ.get("LLAMA_GUARD_MODEL", "llama-guard-3-8b-awq")

    async def async_moderation_hook(self, data, user_api_key_dict: UserAPIKeyAuth, call_type):
        messages = data.get("messages", [])
        if not messages:
            return

        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                f"{self.api_base}/chat/completions",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json={"model": self.model, "messages": messages, "max_tokens": 20},
            )
            resp.raise_for_status()
            verdict = resp.json()["choices"][0]["message"]["content"].strip()

        if verdict.lower().startswith("unsafe"):
            category = verdict.split("\n", 1)[1] if "\n" in verdict else "unspecified"
            raise ValueError(
                f"Blocked by Llama Guard content safety check (category: {category})"
            )
