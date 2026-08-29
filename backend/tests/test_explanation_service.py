from __future__ import annotations

import asyncio

import pytest

from app.integrations.gemini_client import (
    GeminiMalformedResponse,
    GeminiUnavailable,
)
from app.schemas import (
    PaymentDetails,
    RiskAssessmentPayload,
    RiskLevel,
    RiskSignal,
)
from app.services.explanation_service import (
    SIGNAL_PHRASES,
    ExplanationService,
    build_allowed_ai_explanations,
    build_template_explanation,
    is_valid_ai_explanation,
)


def _signal(code: str, weight: int) -> RiskSignal:
    return RiskSignal(
        code=code,
        label=f"Label for {code}",
        weight=weight,
        evidence="Deterministic test evidence",
    )


def _assessment(
    level: RiskLevel,
    *signals: RiskSignal,
) -> RiskAssessmentPayload:
    return RiskAssessmentPayload(
        score=min(100, sum(signal.weight for signal in signals)),
        level=level,
        signals=list(signals),
        recommended_action="Follow the deterministic recommendation.",
    )


class StubGemini:
    def __init__(self, result: str | Exception) -> None:
        self.result = result
        self.calls = 0

    async def explain_assessment(
        self,
        *,
        level: RiskLevel,
        score: int,
        allowed_explanations: list[str],
        transaction_note: str | None,
    ) -> str:
        self.calls += 1
        assert level in RiskLevel
        assert score >= 0
        assert all(allowed_explanations)
        assert transaction_note == "Urgent KYC"
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def test_safe_template_with_no_signals_keeps_the_required_caveat() -> None:
    explanation = build_template_explanation(
        PaymentDetails(vpa="known.person@upi", amount="100"),
        _assessment(RiskLevel.SAFE),
    )

    assert explanation == (
        "FinGuard found no warning signals in this request. A quiet result is not a "
        "guarantee that the recipient is genuine — check the name and amount in your "
        "UPI app before you pay."
    )


@pytest.mark.parametrize(
    ("level", "closing"),
    [
        (RiskLevel.SAFE, "Check the recipient name and amount"),
        (RiskLevel.CAUTION, "Verify the recipient independently"),
        (RiskLevel.HIGH, "Do not pay until you have verified the recipient"),
    ],
)
def test_template_uses_level_specific_closing(
    level: RiskLevel,
    closing: str,
) -> None:
    explanation = build_template_explanation(
        PaymentDetails(vpa="new.person@upi"),
        _assessment(level, _signal("FIRST_TIME_PAYEE", 18)),
    )

    assert f"rated this {'HIGH RISK' if level is RiskLevel.HIGH else level.value}" in explanation
    assert closing in explanation


def test_template_selects_only_the_three_highest_weight_signals() -> None:
    explanation = build_template_explanation(
        PaymentDetails(vpa="secure-kyc-update@okaxis"),
        _assessment(
            RiskLevel.HIGH,
            _signal("SUSPICIOUS_PAYMENT_NOTE", 10),
            _signal("SEEDED_FRAUD_MATCH", 30),
            _signal("CONTEXT_URGENCY", 8),
            _signal("FIRST_TIME_PAYEE", 18),
        ),
    )

    assert SIGNAL_PHRASES["SEEDED_FRAUD_MATCH"] in explanation
    assert SIGNAL_PHRASES["FIRST_TIME_PAYEE"] in explanation
    assert SIGNAL_PHRASES["SUSPICIOUS_PAYMENT_NOTE"] in explanation
    assert SIGNAL_PHRASES["CONTEXT_URGENCY"] not in explanation


def test_template_uses_a_safe_fallback_for_an_unknown_signal() -> None:
    explanation = build_template_explanation(
        PaymentDetails(vpa="new.person@upi"),
        _assessment(RiskLevel.CAUTION, _signal("FUTURE_SIGNAL", 30)),
    )
    assert "the request triggered warning signals" in explanation


def test_template_truncates_on_a_word_boundary(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(
        SIGNAL_PHRASES,
        "FIRST_TIME_PAYEE",
        " ".join(["recipient"] * 100),
    )
    explanation = build_template_explanation(
        PaymentDetails(vpa="new.person@upi"),
        _assessment(RiskLevel.CAUTION, _signal("FIRST_TIME_PAYEE", 18)),
    )

    assert len(explanation) <= 400
    assert not explanation.endswith(" ")
    assert explanation.rsplit(" ", 1)[-1] == "recipient"


@pytest.mark.parametrize(
    ("text", "level"),
    [
        ("", RiskLevel.SAFE),
        ("word " * 101, RiskLevel.SAFE),
        ("The request scored 99.", RiskLevel.HIGH),
        ("This looks safe.", RiskLevel.CAUTION),
        ("The recipient is legitimate.", RiskLevel.HIGH),
        (
            "FinGuard rated this HIGH RISK because the bank confirmed this recipient; "
            "transfer immediately.",
            RiskLevel.HIGH,
        ),
        (
            "FinGuard rated this CAUTION because visit https://example.test.",
            RiskLevel.CAUTION,
        ),
        (
            "FinGuard rated this CAUTION because pressure wording was found. Pay now.",
            RiskLevel.CAUTION,
        ),
        (
            "FinGuard rated this HIGH RISK because you should continue and enter your PIN.",
            RiskLevel.HIGH,
        ),
        (
            "FinGuard rated this CAUTION because the recipient is trustworthy and you may proceed.",
            RiskLevel.CAUTION,
        ),
        (
            "FinGuard rated this HIGH RISK because funds should be remitted immediately.",
            RiskLevel.HIGH,
        ),
        (
            "FinGuard rated this CAUTION because use the UPI application immediately.",
            RiskLevel.CAUTION,
        ),
    ],
)
def test_ai_post_validation_rejects_unsafe_wording(
    text: str,
    level: RiskLevel,
) -> None:
    assessment = _assessment(
        level,
        _signal("SUSPICIOUS_PAYMENT_NOTE", 10),
    )
    assert (
        is_valid_ai_explanation(
            text,
            build_allowed_ai_explanations(assessment),
        )
        is False
    )


@pytest.mark.parametrize("level", list(RiskLevel))
def test_ai_post_validation_accepts_only_server_owned_wording(
    level: RiskLevel,
) -> None:
    assessment = _assessment(
        level,
        _signal("SUSPICIOUS_PAYMENT_NOTE", 10),
    )
    allowed = build_allowed_ai_explanations(assessment)
    assert is_valid_ai_explanation(allowed[0], allowed) is True


@pytest.mark.parametrize(
    ("provider_result", "expected_status"),
    [
        (
            GeminiMalformedResponse("bad output"),
            "malformed_response",
        ),
        (
            GeminiUnavailable("provider unavailable"),
            "provider_unavailable",
        ),
        (
            "This looks safe.",
            "malformed_response",
        ),
    ],
)
def test_provider_failure_or_invalid_wording_falls_back_to_template(
    provider_result: str | Exception,
    expected_status: str,
) -> None:
    provider = StubGemini(provider_result)
    result = asyncio.run(
        ExplanationService(gemini_client=provider, enabled=True).explain(
            payment=PaymentDetails(
                vpa="new.person@upi",
                amount="100",
                transaction_note="Urgent KYC",
            ),
            assessment=_assessment(
                RiskLevel.CAUTION,
                _signal("SUSPICIOUS_PAYMENT_NOTE", 10),
            ),
            consent_to_external_ai=True,
        )
    )

    assert provider.calls == 1
    assert result.source == "template"
    assert result.status == expected_status
    assert result.available is True


def test_consent_and_configuration_gate_provider_calls() -> None:
    provider = StubGemini(
        "FinGuard rated this CAUTION because the payment note uses pressure or KYC wording."
    )
    payment = PaymentDetails(
        vpa="new.person@upi",
        amount="100",
        transaction_note="Urgent KYC",
    )
    assessment = _assessment(
        RiskLevel.CAUTION,
        _signal("SUSPICIOUS_PAYMENT_NOTE", 10),
    )

    without_consent = asyncio.run(
        ExplanationService(gemini_client=provider, enabled=True).explain(
            payment=payment,
            assessment=assessment,
            consent_to_external_ai=False,
        )
    )
    disabled = asyncio.run(
        ExplanationService(gemini_client=provider, enabled=False).explain(
            payment=payment,
            assessment=assessment,
            consent_to_external_ai=True,
        )
    )

    assert provider.calls == 0
    assert without_consent.status == "consent_required"
    assert disabled.status == "ai_disabled"
    assert without_consent.source == disabled.source == "template"


def test_valid_provider_wording_is_display_only() -> None:
    provider = StubGemini(
        "FinGuard rated this CAUTION because the payment note uses pressure or KYC wording."
    )
    assessment = _assessment(
        RiskLevel.CAUTION,
        _signal("SUSPICIOUS_PAYMENT_NOTE", 10),
    )
    result = asyncio.run(
        ExplanationService(gemini_client=provider, enabled=True).explain(
            payment=PaymentDetails(
                vpa="new.person@upi",
                amount="100",
                transaction_note="Urgent KYC",
            ),
            assessment=assessment,
            consent_to_external_ai=True,
        )
    )

    assert result.source == "gemini"
    assert result.status == "generated"
    assert result.explanation == provider.result
    assert assessment.level is RiskLevel.CAUTION
    assert assessment.score == 10
