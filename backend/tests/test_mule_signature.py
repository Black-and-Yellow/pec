from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from app.repositories.reputation_repository import ReputationSnapshot
from app.services import mule_signature


def snapshot(
    *,
    check_count: int = 0,
    distinct_device_count: int = 0,
    recent_new_device_count: int = 0,
    age_days: int = 0,
    safe_count: int = 0,
    caution_count: int = 0,
    high_count: int = 0,
    reported_count: int = 0,
) -> ReputationSnapshot:
    now = datetime.now(UTC)
    return ReputationSnapshot(
        vpa="collector@okaxis",
        first_seen_at=now - timedelta(days=age_days) if check_count else None,
        last_seen_at=now if check_count else None,
        check_count=check_count,
        distinct_device_count=distinct_device_count,
        safe_count=safe_count,
        caution_count=caution_count,
        high_count=high_count,
        reported_count=reported_count,
        recent_new_device_count=recent_new_device_count,
    )


def test_an_address_nobody_has_checked_reports_no_pattern() -> None:
    result = mule_signature.assess(snapshot())
    assert result.matched is False
    assert "no record" in result.evidence


def test_a_missing_snapshot_is_not_an_error() -> None:
    assert mule_signature.assess(None).matched is False


def test_the_collection_shape_is_recognised() -> None:
    # Nine strangers, none of them twice, almost all arriving in the recent
    # window, against an address four days old.
    result = mule_signature.assess(
        snapshot(
            check_count=9,
            distinct_device_count=9,
            recent_new_device_count=8,
            age_days=4,
        )
    )
    assert result.matched is True
    assert result.payer_count == 9
    assert "9 different people" in result.evidence


def test_the_wording_never_asserts_fraud() -> None:
    result = mule_signature.assess(
        snapshot(
            check_count=9,
            distinct_device_count=9,
            recent_new_device_count=8,
            age_days=4,
        )
    )
    # A busy new stall produces this same shape, so the sentence the user reads
    # has to remain true when the payee is innocent.
    assert "not as proof of fraud" in result.evidence


def test_too_few_payers_is_noise_not_a_pattern() -> None:
    result = mule_signature.assess(
        snapshot(
            check_count=4,
            distinct_device_count=4,
            recent_new_device_count=4,
            age_days=1,
        )
    )
    assert result.matched is False


def test_repeat_customers_defeat_the_pattern() -> None:
    # Forty checks from eight people: this address has regulars, which is the
    # one thing a burned collection account never accumulates.
    result = mule_signature.assess(
        snapshot(
            check_count=40,
            distinct_device_count=8,
            recent_new_device_count=8,
            age_days=5,
        )
    )
    assert result.matched is False
    assert result.single_visit_ratio == pytest.approx(0.2)


def test_an_established_address_is_not_a_fresh_collector() -> None:
    result = mule_signature.assess(
        snapshot(
            check_count=30,
            distinct_device_count=30,
            recent_new_device_count=30,
            age_days=200,
        )
    )
    assert result.matched is False
    assert result.tenure_days == 200


def test_steady_growth_without_a_burst_does_not_match() -> None:
    # Thirty one-time payers over three weeks, but only three of them arrived
    # recently: that is a shop finding customers, not an account being drained.
    result = mule_signature.assess(
        snapshot(
            check_count=30,
            distinct_device_count=30,
            recent_new_device_count=3,
            age_days=21,
        )
    )
    assert result.matched is False
    assert result.burst_ratio == pytest.approx(0.1)


def test_one_payers_checks_never_flip_the_verdict() -> None:
    """A single observer must not be able to change what an address looks like.

    Every check lands in the payee's own ledger, so a payer who looks at the
    same address repeatedly shifts the very ratios being read. The verdict has
    to survive that: this walks the marketplace-seller shape through one payer
    checking it ten times and asserts the answer never changes.
    """
    checks, devices, recent = 11, 9, 5
    verdicts: set[bool] = set()
    for attempt in range(10):
        verdicts.add(
            mule_signature.assess(
                snapshot(
                    check_count=checks,
                    distinct_device_count=devices,
                    recent_new_device_count=recent,
                    age_days=21,
                )
            ).matched
        )
        # First look adds a device and widens the recent window; every look
        # after that only adds another check from someone already counted.
        checks += 1
        if attempt == 0:
            devices += 1
            recent += 1
    assert verdicts == {False}


def test_a_decisive_collector_still_matches_after_the_tightening() -> None:
    # The seeded fake-KYC address: 57 payers in 9 days, none of them returning.
    result = mule_signature.assess(
        snapshot(
            check_count=64,
            distinct_device_count=57,
            recent_new_device_count=57,
            age_days=9,
        )
    )
    assert result.matched is True


def test_evidence_fits_the_schema() -> None:
    """The signal is useless if the response cannot carry it.

    RiskSignal.evidence caps at 300 characters and a violation surfaces as a
    500, not as a missing signal, so the ceiling is checked at the widest
    counts this can produce rather than at a typical one.
    """
    from app.schemas import RiskSignal

    result = mule_signature.assess(
        snapshot(
            check_count=9999,
            distinct_device_count=9999,
            recent_new_device_count=9999,
            age_days=29,
        )
    )
    assert result.matched is True
    assert len(result.evidence) <= 300
    # Constructing the model is the real assertion: it fails the same way the
    # API would if the wording ever grows past the limit again.
    RiskSignal(
        code="MULE_ACCOUNT_SIGNATURE",
        label="This address is collecting like a money-mule account",
        weight=22,
        evidence=result.evidence,
    )


def test_a_same_day_burst_reads_as_today() -> None:
    result = mule_signature.assess(
        snapshot(
            check_count=12,
            distinct_device_count=12,
            recent_new_device_count=12,
            age_days=0,
        )
    )
    assert result.matched is True
    assert "today" in result.evidence
