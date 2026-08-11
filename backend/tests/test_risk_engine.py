from __future__ import annotations

from decimal import Decimal

import pytest

from app.db.models import FraudIndicator
from app.risk_policy import RiskWeights
from app.schemas import ContextSignals, PaymentDetails, RiskLevel
from app.services.risk_engine import RiskEngine, RiskInputs


def _indicator() -> FraudIndicator:
    return FraudIndicator(
        id="test-seeded-indicator",
        indicator_type="VPA",
        normalized_value="secure-kyc-update@okaxis",
        label="Seeded fake KYC payment recipient",
        report_count=3,
        relationships={"suspicious_urls": ["example.invalid"], "reported_phones": ["DEMO"]},
        source="SEEDED_DEMO_DATA",
    )


def test_known_safe_demo_transaction() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="coffee.corner@okaxis",
                payee_name="Coffee Corner",
                amount="180.00",
                transaction_note="Coffee",
            ),
            known_payee=True,
            typical_amount=Decimal("240"),
            indicator=None,
        )
    )
    assert result.score == 0
    assert result.level is RiskLevel.SAFE
    assert result.signals == []


def test_caution_demo_transaction() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="market.seller@okaxis",
                amount="4500.00",
                transaction_note="Order payment",
            ),
            known_payee=False,
            typical_amount=Decimal("240"),
            indicator=None,
        )
    )
    assert result.score == 33
    assert result.level is RiskLevel.CAUTION
    assert [signal.code for signal in result.signals] == [
        "FIRST_TIME_PAYEE",
        "UNUSUAL_AMOUNT",
    ]


@pytest.mark.parametrize(
    ("known_payee", "expected_score"),
    [(True, 30), (False, 48)],
)
def test_missing_amount_is_an_explainable_caution(
    known_payee: bool, expected_score: int
) -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="static.qr@upi"),
            known_payee=known_payee,
            typical_amount=Decimal("240"),
            indicator=None,
        )
    )

    assert result.score == expected_score
    assert result.level is RiskLevel.CAUTION
    amount_signal = next(
        signal for signal in result.signals if signal.code == "AMOUNT_NOT_SPECIFIED"
    )
    assert amount_signal.weight == 30
    assert "could not evaluate" in amount_signal.evidence


def test_seeded_scam_transaction() -> None:
    context = ContextSignals(
        impersonation=False,
        urgency=True,
        kyc_threat=True,
        reward_or_refund_claim=False,
        payment_requested=True,
        suspicious_support_claim=False,
        confidence=0.96,
    )
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="secure-kyc-update@okaxis",
                amount="25000.00",
                transaction_note="Urgent KYC account block",
            ),
            known_payee=False,
            typical_amount=Decimal("240"),
            indicator=_indicator(),
            context=context,
        )
    )
    assert result.score == 99
    assert result.level is RiskLevel.HIGH
    assert "SEEDED_FRAUD_MATCH" in {signal.code for signal in result.signals}


def test_risk_score_is_clamped_to_100() -> None:
    context = ContextSignals(
        impersonation=True,
        urgency=True,
        kyc_threat=True,
        reward_or_refund_claim=True,
        payment_requested=True,
        suspicious_support_claim=True,
        confidence=1,
    )
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="secure-kyc-update@okaxis",
                amount="99999.00",
                transaction_note="Urgent KYC refund customer care",
            ),
            known_payee=False,
            typical_amount=Decimal("100"),
            indicator=_indicator(),
            context=context,
        )
    )
    assert sum(signal.weight for signal in result.signals) > 100
    assert result.score == 100


def test_scoring_is_deterministic() -> None:
    inputs = RiskInputs(
        payment=PaymentDetails(vpa="new.person@upi", amount="4500.00"),
        known_payee=False,
        typical_amount=Decimal("500"),
        indicator=None,
    )
    engine = RiskEngine()
    first = engine.score(inputs).model_dump()
    second = engine.score(inputs).model_dump()
    assert first == second


@pytest.mark.parametrize(
    ("score", "expected_level"),
    [
        (29, RiskLevel.SAFE),
        (30, RiskLevel.CAUTION),
        (69, RiskLevel.CAUTION),
        (70, RiskLevel.HIGH),
    ],
)
def test_central_threshold_boundaries(score: int, expected_level: RiskLevel) -> None:
    engine = RiskEngine(weights=RiskWeights(first_time_payee=score))
    result = engine.score(
        RiskInputs(
            payment=PaymentDetails(vpa="new.person@upi", amount="100.00"),
            known_payee=False,
            typical_amount=None,
            indicator=None,
        )
    )
    assert result.score == score
    assert result.level is expected_level


def test_low_confidence_context_cannot_change_deterministic_score() -> None:
    context = ContextSignals(
        impersonation=True,
        urgency=True,
        kyc_threat=True,
        reward_or_refund_claim=True,
        payment_requested=True,
        suspicious_support_claim=True,
        confidence=0.54,
    )
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="known.person@upi", amount="100.00"),
            known_payee=True,
            typical_amount=Decimal("100"),
            indicator=None,
            context=context,
        )
    )
    assert result.score == 0
    assert result.signals == []


def test_seeded_scam_remains_high_risk_without_ai_context() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="secure-kyc-update@okaxis",
                amount="25000.00",
                transaction_note="Urgent KYC account block",
            ),
            known_payee=False,
            typical_amount=Decimal("240"),
            indicator=_indicator(),
            context=None,
        )
    )
    assert result.score == 81
    assert result.level is RiskLevel.HIGH
