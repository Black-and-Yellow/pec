from __future__ import annotations

import asyncio
import base64
import json

import pytest

from app.integrations.gemini_client import (
    GeminiClient,
    GeminiMalformedResponse,
    GeminiUnavailable,
)
from app.schemas import ContextAnalyzeRequest, ContextSignals
from app.services.context_analyzer import (
    ContextAnalyzer,
    ContextInputError,
    local_text_analysis,
    validate_screenshot,
)


class MalformedGemini:
    async def analyze_context(
        self,
        *,
        text: str | None,
        screenshot_bytes: bytes | None,
        screenshot_mime_type: str | None,
    ) -> ContextSignals:
        raise GeminiMalformedResponse("bad output")


class UnavailableGemini:
    async def analyze_context(
        self,
        *,
        text: str | None,
        screenshot_bytes: bytes | None,
        screenshot_mime_type: str | None,
    ) -> ContextSignals:
        raise GeminiUnavailable("quota exhausted")


class RecordingGemini:
    def __init__(self) -> None:
        self.calls = 0

    async def analyze_context(
        self,
        *,
        text: str | None,
        screenshot_bytes: bytes | None,
        screenshot_mime_type: str | None,
    ) -> ContextSignals:
        self.calls += 1
        return ContextSignals(
            impersonation=False,
            urgency=True,
            kyc_threat=False,
            reward_or_refund_claim=False,
            payment_requested=True,
            suspicious_support_claim=False,
            confidence=0.8,
        )


class SuccessfulGeminiResponse:
    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, object]:
        context = {
            "impersonation": False,
            "urgency": True,
            "kyc_threat": False,
            "reward_or_refund_claim": False,
            "payment_requested": True,
            "suspicious_support_claim": False,
            "confidence": 0.8,
        }
        return {"candidates": [{"content": {"parts": [{"text": json.dumps(context)}]}}]}


class RecordingHttpClient:
    def __init__(self) -> None:
        self.endpoint = ""
        self.headers: dict[str, str] = {}
        self.payload: dict[str, object] = {}

    async def __aenter__(self) -> RecordingHttpClient:
        return self

    async def __aexit__(self, *_: object) -> None:
        return None

    async def post(
        self, endpoint: str, *, headers: dict[str, str], json: dict[str, object]
    ) -> SuccessfulGeminiResponse:
        self.endpoint = endpoint
        self.headers = headers
        self.payload = json
        return SuccessfulGeminiResponse()


def test_gemini_unavailable_falls_back_to_local_rules() -> None:
    analyzer = ContextAnalyzer(
        gemini_client=None,
        enabled=True,
        maximum_screenshot_bytes=2_000_000,
    )
    result = asyncio.run(
        analyzer.analyze(
            ContextAnalyzeRequest(
                text="Urgent: complete KYC now or your account will be blocked. Pay by UPI.",
                consent_to_external_ai=True,
            )
        )
    )
    assert result.available is False
    assert result.status == "ai_disabled"
    assert result.source == "local_rules"
    assert result.context.urgency is True
    assert result.context.kyc_threat is True
    assert result.context.payment_requested is True


def test_malformed_gemini_output_uses_safe_fallback() -> None:
    analyzer = ContextAnalyzer(
        gemini_client=MalformedGemini(),
        enabled=True,
        maximum_screenshot_bytes=2_000_000,
    )
    result = asyncio.run(
        analyzer.analyze(
            ContextAnalyzeRequest(
                text="Urgent KYC payment required",
                consent_to_external_ai=True,
            )
        )
    )
    assert result.available is False
    assert result.status == "malformed_response"
    assert result.source == "local_rules"
    assert result.context.kyc_threat is True


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"candidates": []},
        {"candidates": [{"content": {"parts": [{"text": "not-json"}]}}]},
        {
            "candidates": [
                {"content": {"parts": [{"text": '{"urgency":true,"extra":"unsafe"}'}]}}
            ]
        },
    ],
)
def test_gemini_parser_rejects_malformed_structured_output(payload: dict[str, object]) -> None:
    with pytest.raises(GeminiMalformedResponse):
        GeminiClient.parse_response(payload)


def test_gemini_parser_accepts_only_strict_complete_signals() -> None:
    context = {
        "impersonation": False,
        "urgency": True,
        "kyc_threat": True,
        "reward_or_refund_claim": False,
        "payment_requested": True,
        "suspicious_support_claim": False,
        "confidence": 0.91,
    }
    envelope = {"candidates": [{"content": {"parts": [{"text": json.dumps(context)}]}}]}
    assert GeminiClient.parse_response(envelope).model_dump() == context

    for field, invalid_value in (("urgency", 1), ("confidence", "0.91")):
        invalid = context | {field: invalid_value}
        envelope["candidates"][0]["content"]["parts"][0]["text"] = json.dumps(invalid)
        with pytest.raises(GeminiMalformedResponse):
            GeminiClient.parse_response(envelope)


def test_explicit_consent_controls_provider_calls() -> None:
    provider = RecordingGemini()
    analyzer = ContextAnalyzer(
        gemini_client=provider,
        enabled=True,
        maximum_screenshot_bytes=2_000_000,
    )
    without_consent = asyncio.run(analyzer.analyze(ContextAnalyzeRequest(text="Pay now")))
    assert without_consent.status == "consent_required"
    assert without_consent.source == "local_rules"
    assert provider.calls == 0

    with_consent = asyncio.run(
        analyzer.analyze(
            ContextAnalyzeRequest(text="Pay now", consent_to_external_ai=True)
        )
    )
    assert with_consent.status == "analyzed"
    assert with_consent.source == "gemini"
    assert provider.calls == 1


def test_provider_outage_preserves_local_deterministic_signals() -> None:
    analyzer = ContextAnalyzer(
        gemini_client=UnavailableGemini(),
        enabled=True,
        maximum_screenshot_bytes=2_000_000,
    )
    result = asyncio.run(
        analyzer.analyze(
            ContextAnalyzeRequest(
                text="Urgent KYC payment required",
                consent_to_external_ai=True,
            )
        )
    )
    assert result.available is False
    assert result.status == "provider_unavailable"
    assert result.source == "local_rules"
    assert result.context.urgency is True
    assert result.context.kyc_threat is True


def test_screenshot_size_and_declared_type_are_enforced() -> None:
    png = b"\x89PNG\r\n\x1a\n" + b"content"
    encoded = base64.b64encode(png).decode("ascii")
    assert validate_screenshot(encoded, "image/png", maximum_bytes=len(png)) == png

    with pytest.raises(ContextInputError, match="byte limit"):
        validate_screenshot(encoded, "image/png", maximum_bytes=len(png) - 1)
    with pytest.raises(ContextInputError, match="declared image MIME type"):
        validate_screenshot(encoded, "image/jpeg", maximum_bytes=len(png))


def test_local_rules_recognize_rupee_payment_language() -> None:
    result = local_text_analysis("Send ₹500 now")
    assert result.payment_requested is True
    assert result.urgency is False


def test_gemini_request_keeps_key_out_of_url_and_bounds_structured_output(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport = RecordingHttpClient()
    monkeypatch.setattr(
        "app.integrations.gemini_client.httpx.AsyncClient",
        lambda *, timeout: transport,
    )
    client = GeminiClient(
        api_key="test-secret-key",
        model="gemini-2.5-flash-lite",
        timeout_seconds=12,
    )
    result = asyncio.run(
        client.analyze_context(
            text="Pay immediately",
            screenshot_bytes=None,
            screenshot_mime_type=None,
        )
    )

    assert result.urgency is True
    assert "test-secret-key" not in transport.endpoint
    assert transport.headers["x-goog-api-key"] == "test-secret-key"
    generation_config = transport.payload["generationConfig"]
    assert isinstance(generation_config, dict)
    assert generation_config["responseMimeType"] == "application/json"
    assert generation_config["responseJsonSchema"] is not None
    assert generation_config["maxOutputTokens"] == 512
