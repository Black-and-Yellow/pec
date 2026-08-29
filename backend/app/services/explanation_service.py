from __future__ import annotations

from typing import Literal, Protocol

from app.integrations.gemini_client import (
    GeminiMalformedResponse,
    GeminiUnavailable,
)
from app.schemas import (
    PaymentDetails,
    RiskAssessmentPayload,
    RiskExplainResponse,
    RiskLevel,
)

SIGNAL_PHRASES: dict[str, str] = {
    "SEEDED_FRAUD_MATCH": ("this recipient appears in FinGuard's labelled scam indicator list"),
    "FIRST_TIME_PAYEE": "you have never paid this recipient from this device",
    "AMOUNT_NOT_SPECIFIED": "the request lets the amount be filled in later",
    "UNUSUAL_AMOUNT": "the amount is much larger than your usual payments",
    "SUSPICIOUS_PAYMENT_NOTE": "the payment note uses pressure or KYC wording",
    "SEEDED_IDENTIFIER_RELATIONSHIP": ("the recipient is linked to other reported identifiers"),
    "CONTEXT_IMPERSONATION": ("the message you supplied impersonates a trusted organisation"),
    "CONTEXT_URGENCY": "the message pressures you to act immediately",
    "CONTEXT_KYC_THREAT": "the message threatens to block your account over KYC",
    "CONTEXT_REWARD_OR_REFUND": "the message promises a refund or reward",
    "CONTEXT_SUSPICIOUS_SUPPORT": ("the message claims to be support you did not contact"),
}

_MAX_EXPLANATION_LENGTH = 400
TemplateStatus = Literal[
    "ai_disabled",
    "consent_required",
    "provider_unavailable",
    "malformed_response",
]


class ExplanationProvider(Protocol):
    async def explain_assessment(
        self,
        *,
        level: RiskLevel,
        score: int,
        allowed_explanations: list[str],
        transaction_note: str | None,
    ) -> str: ...


def _join_reasons(reasons: list[str]) -> str:
    if len(reasons) == 1:
        return reasons[0]
    if len(reasons) == 2:
        return f"{reasons[0]} and {reasons[1]}"
    return f"{', '.join(reasons[:-1])} and {reasons[-1]}"


def _truncate_at_word_boundary(text: str) -> str:
    normalized = " ".join(text.split())
    if len(normalized) <= _MAX_EXPLANATION_LENGTH:
        return normalized
    shortened = normalized[: _MAX_EXPLANATION_LENGTH + 1].rsplit(" ", 1)[0]
    return shortened or normalized[:_MAX_EXPLANATION_LENGTH]


def _assessment_reasons(assessment: RiskAssessmentPayload) -> list[str]:
    top_signals = sorted(
        assessment.signals,
        key=lambda signal: signal.weight,
        reverse=True,
    )[:3]
    reasons = [
        SIGNAL_PHRASES[signal.code] for signal in top_signals if signal.code in SIGNAL_PHRASES
    ]
    return reasons or ["the request triggered warning signals"]


def build_allowed_ai_explanations(
    assessment: RiskAssessmentPayload,
) -> tuple[str, ...]:
    reasons = (
        ["no configured warning signal fired"]
        if assessment.level is RiskLevel.SAFE and not assessment.signals
        else _assessment_reasons(assessment)
    )
    clauses = [*reasons]
    if len(reasons) > 1:
        clauses.append(_join_reasons(reasons))
    display_level = "HIGH RISK" if assessment.level is RiskLevel.HIGH else assessment.level.value
    return tuple(
        dict.fromkeys(
            f"FinGuard rated this {display_level} because {clause}." for clause in clauses
        )
    )


def build_template_explanation(
    payment: PaymentDetails,
    assessment: RiskAssessmentPayload,
) -> str:
    del payment  # The deterministic signal record already contains the assessed facts.
    if assessment.level is RiskLevel.SAFE and not assessment.signals:
        return (
            "FinGuard found no warning signals in this request. A quiet result is not a "
            "guarantee that the recipient is genuine — check the name and amount in your "
            "UPI app before you pay."
        )

    reasons = _assessment_reasons(assessment)

    display_level = "HIGH RISK" if assessment.level is RiskLevel.HIGH else assessment.level.value
    closing = {
        RiskLevel.SAFE: (" Check the recipient name and amount in your UPI app before you pay."),
        RiskLevel.CAUTION: (" Verify the recipient independently before you continue."),
        RiskLevel.HIGH: (
            " Do not pay until you have verified the recipient through a channel you already trust."
        ),
    }[assessment.level]
    return _truncate_at_word_boundary(
        f"FinGuard rated this {display_level} because {_join_reasons(reasons)}.{closing}"
    )


def is_valid_ai_explanation(
    explanation: str,
    allowed_explanations: tuple[str, ...],
) -> bool:
    normalized = " ".join(explanation.split())
    return (
        bool(normalized)
        and len(normalized) <= _MAX_EXPLANATION_LENGTH
        and normalized in allowed_explanations
    )


class ExplanationService:
    def __init__(
        self,
        *,
        gemini_client: ExplanationProvider | None,
        enabled: bool,
    ) -> None:
        self._gemini_client = gemini_client
        self._enabled = enabled

    async def explain(
        self,
        *,
        payment: PaymentDetails,
        assessment: RiskAssessmentPayload,
        consent_to_external_ai: bool,
    ) -> RiskExplainResponse:
        template = build_template_explanation(payment, assessment)
        if not consent_to_external_ai:
            return self._template_response(template, status="consent_required")
        if not self._enabled or self._gemini_client is None:
            return self._template_response(template, status="ai_disabled")

        allowed_explanations = build_allowed_ai_explanations(assessment)
        try:
            explanation = await self._gemini_client.explain_assessment(
                level=assessment.level,
                score=assessment.score,
                allowed_explanations=list(allowed_explanations),
                transaction_note=payment.transaction_note,
            )
        except GeminiMalformedResponse:
            return self._template_response(template, status="malformed_response")
        except GeminiUnavailable:
            return self._template_response(template, status="provider_unavailable")

        if not is_valid_ai_explanation(explanation, allowed_explanations):
            return self._template_response(template, status="malformed_response")
        return RiskExplainResponse(
            available=True,
            source="gemini",
            status="generated",
            explanation=" ".join(explanation.split()),
        )

    @staticmethod
    def _template_response(
        explanation: str,
        *,
        status: TemplateStatus,
    ) -> RiskExplainResponse:
        return RiskExplainResponse(
            available=True,
            source="template",
            status=status,
            explanation=explanation,
        )
