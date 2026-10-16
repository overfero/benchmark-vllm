# Content-safety guardrail backed by Laya (https://huggingface.co/convaiinnovations/laya),
# a 421M non-autoregressive "System 1" classifier - not a chat model, so it
# replaces the old separate Llama-Guard-3-8B-AWQ vLLM instance entirely
# (served on Zrok9, see ../../service_laya.sh). It answers a single typed
# ALLOW/DECLINE question in one forward pass instead of generating text.
#
# Served via laya-serve's Jev-compatible HTTP contract (POST /v1/systemone),
# with the fine-tuned safety checkpoint (https://huggingface.co/Dipto084/safe_laya)
# registered server-side as LAYA_EXTRA_MODELS={"safe-laya": "Dipto084/safe_laya"}.
#
# Follows LiteLLM's documented Custom Guardrail interface:
# https://docs.litellm.ai/docs/proxy/guardrails/custom_guardrail
# async_moderation_hook (the during_call hook) is the right fit since it can
# only block, never modify - matches a safe/unsafe classifier.
import os

import httpx

from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.proxy._types import UserAPIKeyAuth

# Same ALLOW/DECLINE question shape as safe_laya's own model card example.
SAFETY_QUESTIONS = {
    "action": {
        "type": "choice",
        "instructions": "Should the assistant answer this user message, or decline it?",
        "criteria": {
            "ALLOW": (
                "The message does not indicate harmful intent: it is either not "
                "meaningfully harm-adjacent, or it remains fully consistent with an "
                "ordinary benign request without any strategic narrowing toward "
                "harmful content; or it involves a sensitive or harm-adjacent topic "
                "while the request stays credibly benign in purpose and scope."
            ),
            "DECLINE": (
                "A natural, helpful answer to this message as phrased would require "
                "producing materially harmful or policy-violating content."
            ),
        },
    }
}


class SafetyGuardrail(CustomGuardrail):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.api_base = os.environ.get(
            "LAYA_API_BASE", "http://host.docker.internal:18002"
        )
        self.api_key = os.environ.get("LAYA_API_KEY", "")
        self.model = os.environ.get("LAYA_MODEL", "safe-laya")

    async def async_moderation_hook(self, data, user_api_key_dict: UserAPIKeyAuth, call_type):
        messages = data.get("messages", [])
        if not messages:
            return
        last_user_msg = next(
            (m["content"] for m in reversed(messages) if m.get("role") == "user"), None
        )
        if not last_user_msg:
            return

        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                f"{self.api_base}/v1/systemone",
                headers={"Authorization": f"Bearer {self.api_key}"},
                json={
                    "state": {"body": last_user_msg},
                    "model": self.model,
                    "questions": SAFETY_QUESTIONS,
                },
            )
            resp.raise_for_status()
            action = resp.json()["answers"]["action"]

        if action["choice"] == "DECLINE":
            raise ValueError(
                f"Blocked by content safety check "
                f"(confidence: {action['probabilities']['DECLINE']:.2f})"
            )
