from __future__ import annotations

import base64
import binascii
import re
from typing import Protocol

from app.integrations.gemini_client import (
    GeminiMalformedResponse,
    GeminiUnavailable,
)
from app.schemas import ContextAnalyzeRequest, ContextAnalyzeResponse, ContextSignals

PATTERNS = {
    "impersonation": re.compile(
        r"\b(i am|this is|calling from|on behalf of)\s+(?:your\s+)?(?:bank|police|npci|government)",
        re.IGNORECASE,
    ),
    "urgency": re.compile(
        r"\b(urgent|immediately|right now|act now|final warning|within \d+ (?:minute|hour)s?)\b",
        re.IGNORECASE,
    ),
    "kyc_threat": re.compile(
        r"\bkyc\b|\baccount\s+(?:will be\s+)?(?:block|blocked|freeze|frozen|suspend|suspended)",
        re.IGNORECASE,
    ),
    "reward_or_refund_claim": re.compile(
        r"\b(refund|cashback|reward|prize|lottery|won)\b", re.IGNORECASE
    ),
    "payment_requested": re.compile(
        r"\b(pay|payment|send|transfer|upi|scan (?:this )?qr)\b|\u20b9|\binr\b",
        re.IGNORECASE,
    ),
    "suspicious_support_claim": re.compile(
        r"\b(customer care|support team|support agent|helpline)\b", re.IGNORECASE
    ),
}


class ContextInputError(ValueError):
    pass


class ContextProvider(Protocol):
    async def analyze_context(
        self,
        *,
        text: str | None,
        screenshot_bytes: bytes | None,
        screenshot_mime_type: str | None,
    ) -> ContextSignals: ...


def validate_screenshot(
    encoded: str | None, mime_type: str | None, *, maximum_bytes: int
) -> bytes | None:
    if encoded is None:
        return None
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ContextInputError("screenshot_base64 is not valid base64") from exc
    if not decoded:
        raise ContextInputError("screenshot cannot be empty")
    if len(decoded) > maximum_bytes:
        raise ContextInputError(f"screenshot exceeds the {maximum_bytes}-byte limit")

    signatures = {
        "image/png": decoded.startswith(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg": decoded.startswith(b"\xff\xd8\xff"),
        "image/webp": len(decoded) >= 12
        and decoded.startswith(b"RIFF")
        and decoded[8:12] == b"WEBP",
    }
    if not mime_type or not signatures.get(mime_type, False):
        raise ContextInputError("screenshot bytes do not match the declared image MIME type")
    return decoded


def local_text_analysis(text: str | None) -> ContextSignals:
    content = text or ""
    matches = {name: bool(pattern.search(content)) for name, pattern in PATTERNS.items()}
    match_count = sum(matches.values())
    confidence = min(0.75, 0.35 + (0.12 * match_count)) if match_count else 0.2
    return ContextSignals(**matches, confidence=confidence)


class ContextAnalyzer:
    def __init__(
        self,
        *,
        gemini_client: ContextProvider | None,
        enabled: bool,
        maximum_screenshot_bytes: int,
    ) -> None:
        self._gemini_client = gemini_client
        self._enabled = enabled
        self._maximum_screenshot_bytes = maximum_screenshot_bytes

    async def analyze(self, request: ContextAnalyzeRequest) -> ContextAnalyzeResponse:
        screenshot = validate_screenshot(
            request.screenshot_base64,
            request.screenshot_mime_type,
            maximum_bytes=self._maximum_screenshot_bytes,
        )
        local_context = local_text_analysis(request.text)
        fallback_source = "local_rules" if request.text else "none"

        if not request.consent_to_external_ai:
            return ContextAnalyzeResponse(
                available=False,
                source=fallback_source,
                status="consent_required",
                message=(
                    "Nothing was sent externally. Enable explicit AI consent to analyze with "
                    "Gemini; local text checks are shown where possible."
                ),
                context=local_context,
            )

        if not self._enabled or self._gemini_client is None:
            return ContextAnalyzeResponse(
                available=False,
                source=fallback_source,
                status="ai_disabled",
                message=(
                    "Optional Gemini analysis is not configured. Deterministic payment and local "
                    "text checks remain available."
                ),
                context=local_context,
            )

        try:
            context = await self._gemini_client.analyze_context(
                text=request.text,
                screenshot_bytes=screenshot,
                screenshot_mime_type=request.screenshot_mime_type,
            )
        except GeminiMalformedResponse:
            return ContextAnalyzeResponse(
                available=False,
                source=fallback_source,
                status="malformed_response",
                message=(
                    "Gemini returned an unusable structured response. FinGuard used local text "
                    "checks and deterministic payment scoring instead."
                ),
                context=local_context,
            )
        except GeminiUnavailable:
            return ContextAnalyzeResponse(
                available=False,
                source=fallback_source,
                status="provider_unavailable",
                message=(
                    "Gemini is temporarily unavailable or over quota. FinGuard used local text "
                    "checks and deterministic payment scoring instead."
                ),
                context=local_context,
            )

        return ContextAnalyzeResponse(
            available=True,
            source="gemini",
            status="analyzed",
            message=(
                "Gemini extracted structured context signals; deterministic policy sets the score."
            ),
            context=context,
        )
