from __future__ import annotations

from decimal import Decimal

import pytest

from app.db.models import FraudIndicator
from app.risk_policy import RiskWeights
from app.schemas import (
    ContextSignals,
    PayeeTrust,
    PaymentDetails,
    QrProvenance,
    RiskAssessmentPayload,
    RiskLevel,
    TrustGrade,
    TrustPillar,
    TrustPillarCode,
    TrustPillarStatus,
)
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
    assert [(signal.code, signal.weight) for signal in result.signals] == [
        ("PAYEE_NAME_UNVERIFIED", 0)
    ]


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


def test_missing_amount_alone_stays_safe() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="static.qr@upi"),
            known_payee=False,
            typical_amount=Decimal("240"),
            indicator=None,
        )
    )

    assert result.score == 23
    assert result.level is RiskLevel.SAFE
    amount_signal = next(
        signal for signal in result.signals if signal.code == "AMOUNT_NOT_SPECIFIED"
    )
    assert amount_signal.weight == 5
    assert "normal for a static merchant QR" in amount_signal.evidence


def test_missing_amount_with_seeded_match_escalates() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="secure-kyc-update@okaxis"),
            known_payee=False,
            typical_amount=Decimal("240"),
            indicator=_indicator(),
        )
    )

    amount_signal = next(
        signal for signal in result.signals if signal.code == "AMOUNT_NOT_SPECIFIED"
    )
    assert amount_signal.weight == 20
    assert result.score == 76
    assert result.level is RiskLevel.HIGH


def test_missing_amount_signal_keeps_display_position() -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="secure-kyc-update@okaxis"),
            known_payee=False,
            typical_amount=Decimal("240"),
            indicator=_indicator(),
        )
    )

    signal_codes = [signal.code for signal in result.signals]
    first_time_index = signal_codes.index("FIRST_TIME_PAYEE")
    assert signal_codes[first_time_index + 1] == "AMOUNT_NOT_SPECIFIED"


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


def _payee_trust(grade: TrustGrade) -> PayeeTrust:
    return PayeeTrust(
        vpa="merchant@okaxis",
        score=90,
        grade=grade,
        headline="Synthetic trust report",
        thin_file=False,
        impersonation=False,
        confidence="HIGH",
        pillars=[
            TrustPillar(
                code=TrustPillarCode.IDENTITY,
                label="Address identity",
                points=30,
                maximum=30,
                status=TrustPillarStatus.STRONG,
                evidence="Synthetic test-only trust evidence.",
            )
        ],
        assessed_points=30,
        assessable_maximum=30,
        first_seen_at=None,
        observed_days=365,
        check_count=100,
        distinct_device_count=50,
        reported_count=0,
        disclaimer="Synthetic test-only trust report.",
    )


def _signal_weight(result: RiskAssessmentPayload, code: str) -> int:
    signals = result.signals
    return next(signal.weight for signal in signals if signal.code == code)


def test_trust_scaled_amount_orders_grades_without_unusual_amount_double_counting() -> None:
    grades = [
        TrustGrade.A_PLUS,
        TrustGrade.A,
        TrustGrade.B,
        TrustGrade.C,
        TrustGrade.D,
    ]
    results = [
        RiskEngine().score(
            RiskInputs(
                payment=PaymentDetails(vpa="merchant@okaxis", amount="25000.00"),
                known_payee=False,
                typical_amount=Decimal("100"),
                indicator=None,
                payee_trust=_payee_trust(grade),
            )
        )
        for grade in grades
    ]
    scores = [result.score for result in results]

    assert scores == sorted(scores)
    assert len(set(scores)) == len(scores)
    assert _signal_weight(results[0], "AMOUNT_SCALED_BY_TRUST") == 0
    assert all(_signal_weight(result, "AMOUNT_SCALED_BY_TRUST") <= 20 for result in results)
    assert all(
        "UNUSUAL_AMOUNT" not in {signal.code for signal in result.signals} for result in results
    )


def test_trust_scaled_amount_rises_with_amount() -> None:
    engine = RiskEngine()
    smaller = engine.score(
        RiskInputs(
            payment=PaymentDetails(vpa="merchant@okaxis", amount="2000.00"),
            known_payee=False,
            typical_amount=Decimal("100"),
            indicator=None,
            payee_trust=_payee_trust(TrustGrade.D),
        )
    )
    larger = engine.score(
        RiskInputs(
            payment=PaymentDetails(vpa="merchant@okaxis", amount="25000.00"),
            known_payee=False,
            typical_amount=Decimal("100"),
            indicator=None,
            payee_trust=_payee_trust(TrustGrade.D),
        )
    )

    assert _signal_weight(smaller, "AMOUNT_SCALED_BY_TRUST") < _signal_weight(
        larger, "AMOUNT_SCALED_BY_TRUST"
    )


@pytest.mark.parametrize(
    ("payment", "expected_weight"),
    [
        (PaymentDetails(vpa="merchant@okaxis"), None),
        (PaymentDetails(vpa="merchant@okaxis", payee_name="Coffee Corner"), 0),
        (PaymentDetails(vpa="random@okaxis", payee_name="SBI Refund Cell"), 14),
        (PaymentDetails(vpa="sbi@oksbi", payee_name="SBI Collections"), 0),
    ],
)
def test_payee_name_unverified_is_informational_unless_the_vpa_cannot_back_a_brand(
    payment: PaymentDetails,
    expected_weight: int | None,
) -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=payment,
            known_payee=True,
            typical_amount=None,
            indicator=None,
        )
    )
    names = [signal for signal in result.signals if signal.code == "PAYEE_NAME_UNVERIFIED"]

    if expected_weight is None:
        assert names == []
    else:
        assert len(names) == 1
        assert names[0].weight == expected_weight


@pytest.mark.parametrize(
    ("payment", "provenance", "expected_weight"),
    [
        (
            PaymentDetails(
                vpa="merchant@okaxis",
                amount="500.00",
                transaction_reference="ORDER-42",
            ),
            None,
            None,
        ),
        (
            PaymentDetails(
                vpa="merchant@okaxis",
                amount="500.00",
                transaction_reference="ORDER-42",
            ),
            QrProvenance(),
            8,
        ),
        (
            PaymentDetails(
                vpa="merchant@okaxis",
                amount="500.00",
                transaction_reference="ORDER-42",
            ),
            QrProvenance(sign_present=True),
            None,
        ),
        (
            PaymentDetails(vpa="merchant@okaxis", amount="500.00"),
            QrProvenance(),
            None,
        ),
    ],
)
def test_qr_provenance_is_a_presence_only_risk_raiser(
    payment: PaymentDetails,
    provenance: QrProvenance | None,
    expected_weight: int | None,
) -> None:
    result = RiskEngine().score(
        RiskInputs(
            payment=payment,
            known_payee=True,
            typical_amount=None,
            indicator=None,
            qr_provenance=provenance,
        )
    )
    signals = [signal for signal in result.signals if signal.code == "QR_PROVENANCE_MISSING"]

    if expected_weight is None:
        assert signals == []
    else:
        assert len(signals) == 1
        assert signals[0].weight == expected_weight
