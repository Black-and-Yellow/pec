"""Milestone 2: the published policy must match the policy that actually runs.

The risk of a document like this is that it drifts: a weight is tuned, the
card keeps describing the old one, and the app is now explaining a score it no
longer produces. These tests make drift a build failure.
"""

from __future__ import annotations

import dataclasses
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from app.risk_policy import THRESHOLDS, WEIGHTS, RiskWeights
from app.schemas import PaymentDetails, RiskLevel
from app.services import policy_card
from app.services.policy_card import SIGNAL_RATIONALES, weight_entries
from app.services.risk_engine import RiskEngine, RiskInputs


def test_every_weight_is_documented_exactly_once() -> None:
    fields = [f.name for f in dataclasses.fields(RiskWeights)]
    assert sorted(fields) == sorted(SIGNAL_RATIONALES)
    assert len(SIGNAL_RATIONALES) == len(set(SIGNAL_RATIONALES))
    entries = weight_entries(WEIGHTS)
    assert len(entries) == len(fields)
    assert len({entry["field"] for entry in entries}) == len(fields)


def test_an_undocumented_weight_fails_loudly() -> None:
    """A new weight must not be able to ship without a published reason."""
    extended = dataclasses.make_dataclass(
        "ExtendedWeights",
        [("brand_new_signal", int, dataclasses.field(default=7))],
        bases=(RiskWeights,),
        frozen=True,
    )
    with pytest.raises(ValueError, match="undocumented"):
        weight_entries(extended())


def test_a_stale_rationale_fails_loudly(monkeypatch: pytest.MonkeyPatch) -> None:
    """Describing a weight that no longer exists is equally wrong."""
    stale = dict(SIGNAL_RATIONALES)
    stale["removed_signal"] = next(iter(SIGNAL_RATIONALES.values()))
    monkeypatch.setattr(policy_card, "SIGNAL_RATIONALES", stale)
    with pytest.raises(ValueError, match="stale"):
        weight_entries(WEIGHTS)


def test_published_points_are_the_points_the_engine_uses(client: TestClient) -> None:
    card = client.get("/api/v1/policy/card").json()
    for signal in card["signals"]:
        assert signal["points"] == getattr(WEIGHTS, signal["field"]), signal["field"]


def test_published_bands_match_the_thresholds_in_force(client: TestClient) -> None:
    card = client.get("/api/v1/policy/card").json()
    published = {b["name"]: (b["minimum"], b["maximum"]) for b in card["bands"]}
    assert published["SAFE"] == (0, THRESHOLDS.safe_max)
    assert published["CAUTION"] == (THRESHOLDS.safe_max + 1, THRESHOLDS.caution_max)
    assert published["HIGH"] == (THRESHOLDS.caution_max + 1, 100)
    # The boundaries the demo narrative depends on.
    assert published["SAFE"][1] == 29
    assert published["CAUTION"][0] == 30
    assert published["CAUTION"][1] == 69
    assert published["HIGH"][0] == 70


def test_the_card_refuses_to_claim_statistical_calibration(client: TestClient) -> None:
    card = client.get("/api/v1/policy/card").json()
    statement = card["calibration_statement"]
    assert "not statistically calibrated fraud probabilities" in statement
    assert card["limitations"]
    assert card["policy_version"]


def test_every_rationale_names_a_source(client: TestClient) -> None:
    card = client.get("/api/v1/policy/card").json()
    allowed = {"NPCI_ADVISORY", "RBI_ADVISORY", "I4C_ADVISORY", "FINGUARD_POLICY"}
    for signal in card["signals"]:
        assert signal["source_category"] in allowed
        assert signal["rationale"].strip()


def _score(**kwargs) -> int:
    payment = PaymentDetails(
        vpa=kwargs.pop("vpa", "shop@okaxis"),
        amount=kwargs.pop("amount", None),
        transaction_note=kwargs.pop("note", None),
    )
    return (
        RiskEngine()
        .score(
            RiskInputs(
                payment=payment,
                known_payee=kwargs.pop("known_payee", False),
                typical_amount=kwargs.pop("typical_amount", None),
                indicator=None,
                **kwargs,
            )
        )
        .score
    )


def test_no_weight_is_negative() -> None:
    """A negative weight would let one fact cancel another out of the score."""
    for field in dataclasses.fields(RiskWeights):
        assert getattr(WEIGHTS, field.name) >= 0, field.name


def test_adding_a_signal_never_lowers_the_score() -> None:
    """Adding evidence, holding the request fixed, may only raise the score.

    "Adding a signal" means exactly that: the same request, with one more
    thing true about it. Changing the request itself is a different question -
    stating an amount replaces the open-ended-amount signal with the unusual
    amount one, and that is deliberately allowed to move the score down,
    because a request whose figure the caller dictates is the worse of the two.
    """
    from app.schemas import CallActivity, EnvironmentSignals, RemoteAccessTool

    payment = PaymentDetails(vpa="anita.tailors@ybl", amount=Decimal("25000"))

    def score_with(environment: EnvironmentSignals | None) -> int:
        return (
            RiskEngine()
            .score(
                RiskInputs(
                    payment=payment,
                    known_payee=False,
                    typical_amount=Decimal("200"),
                    indicator=None,
                    environment=environment,
                )
            )
            .score
        )

    baseline = score_with(None)
    with_call = score_with(EnvironmentSignals(call_activity=CallActivity.CELLULAR))
    with_both = score_with(
        EnvironmentSignals(
            call_activity=CallActivity.CELLULAR,
            remote_access_tools=[RemoteAccessTool.ANYDESK],
        )
    )
    assert baseline <= with_call <= with_both


def test_the_three_bands_are_still_reachable() -> None:
    """The demo depends on each band being produced by a real combination."""
    safe = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="anita.tailors@ybl", amount=Decimal("180")),
            known_payee=True,
            typical_amount=Decimal("240"),
            indicator=None,
        )
    )
    assert safe.level is RiskLevel.SAFE

    from app.schemas import CallActivity, EnvironmentSignals, RemoteAccessTool

    caution = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="anita.tailors@ybl", amount=Decimal("25000")),
            known_payee=False,
            typical_amount=Decimal("200"),
            indicator=None,
        )
    )
    assert caution.level is RiskLevel.CAUTION

    high = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(
                vpa="secure-kyc-update@okaxis",
                amount=Decimal("25000"),
                transaction_note="URGENT KYC account block",
            ),
            known_payee=False,
            typical_amount=Decimal("200"),
            indicator=None,
            environment=EnvironmentSignals(
                call_activity=CallActivity.CELLULAR,
                remote_access_tools=[RemoteAccessTool.ANYDESK],
            ),
        )
    )
    assert high.level is RiskLevel.HIGH
