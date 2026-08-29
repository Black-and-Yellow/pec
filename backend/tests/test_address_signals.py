"""The address text is evidence that needs no ledger behind it.

These pin the gap that made a pretext address score identically to a genuine
new payee: with no history the trust grade is NEW either way, so unless the
structure itself reaches the score, nothing distinguishes them.
"""

from __future__ import annotations

from decimal import Decimal

import pytest

from app.schemas import PaymentDetails, RiskLevel
from app.services.risk_engine import RiskEngine, RiskInputs


def assess(vpa: str):
    return RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa=vpa, amount=Decimal("4000")),
            known_payee=False,
            typical_amount=None,
            indicator=None,
        )
    )


def codes(result) -> list[str]:
    return [signal.code for signal in result.signals]


def test_a_pretext_address_is_scored_without_any_history() -> None:
    result = assess("kyc-verify-now@ybl")
    assert "PAYEE_ADDRESS_PRETEXT" in codes(result)
    assert result.level is not RiskLevel.SAFE


def test_a_phone_derived_address_is_scored() -> None:
    result = assess("9876543210@ybl")
    assert "PAYEE_ADDRESS_DISPOSABLE" in codes(result)


def test_an_unknown_handle_is_scored() -> None:
    result = assess("payme@notarealpsp")
    assert "PAYEE_HANDLE_UNRECOGNIZED" in codes(result)


def test_a_clean_new_address_earns_no_structural_signal() -> None:
    # The whole point of the thin-file rule: a real new shop must not be
    # punished for being new, so nothing structural may fire here. The level is
    # deliberately not asserted - scored bare, FIRST_TIME_PAYEE and an unknown
    # typical amount already lift it, and neither is about the address.
    result = assess("anita.tailors@ybl")
    assert not [code for code in codes(result) if code.startswith("PAYEE_ADDRESS")]
    assert "PAYEE_HANDLE_UNRECOGNIZED" not in codes(result)


def test_a_pretext_address_outscores_an_equivalent_clean_one() -> None:
    assert assess("kyc-verify-now@ybl").score > assess("anita.tailors@ybl").score


@pytest.mark.parametrize("vpa", ["sbi-refund@okaxis", "sbi.support@oksbii"])
def test_a_borrowed_brand_never_becomes_a_second_structural_signal(vpa: str) -> None:
    """The brand itself is charged once, through the impersonation signal.

    A pretext word may still fire alongside it, and should: 'sbi-refund' both
    borrows a bank name and names a reason to pay, which are two different
    things wrong with one address rather than one thing counted twice.
    """
    emitted = codes(assess(vpa))
    assert len(emitted) == len(set(emitted))
    assert not [code for code in emitted if "BORROWED" in code or "LOOKALIKE" in code]
