"""Second-opinion review follow-ups.

Three findings, each pinned by the tests below.

1. Preparing an incident draft must never publish anything about a third
   party, for anyone, signed in or not. Reading what a report would say is not
   consent to file it.
2. Community standing may escalate an unusual amount and may never reduce one.
   The ledger is keyed on a client-supplied identifier, so a discount path is
   a path where a manufactured reputation buys silence.
3. The band boundaries are exact and load-bearing for the demo narrative.
"""

from __future__ import annotations

from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from app.risk_policy import THRESHOLDS, WEIGHTS
from app.schemas import PayeeTrust, PaymentDetails, RiskLevel, TrustGrade
from app.services.risk_engine import RiskEngine, RiskInputs

# --------------------------------------------------------------------------
# 1. Draft preparation publishes nothing
# --------------------------------------------------------------------------

VICTIM = "quiet.baker@okhdfcbank"


def prepare_draft(
    client: TestClient,
    vpa: str,
    *,
    headers: dict[str, str] | None = None,
    already_paid: bool = True,
):
    parsed = client.post(
        "/api/v1/payments/parse",
        json={"upi_uri": f"upi://pay?pa={vpa.replace('@', '%40')}&am=500&cu=INR"},
    ).json()
    scored = client.post(
        "/api/v1/risk/score",
        json={"payment": parsed["payment"], "device_id": "review-device"},
    ).json()
    return client.post(
        "/api/v1/response/prepare",
        json={
            "payment": parsed["payment"],
            "assessment": {
                "assessment_id": scored["assessment_id"],
                "score": scored["score"],
                "level": scored["level"],
                "signals": scored["signals"],
                "recommended_action": scored["recommended_action"],
            },
            "already_paid": already_paid,
        },
        headers=headers or {},
    )


def standing(client: TestClient, vpa: str) -> dict:
    body = client.post("/api/v1/trust/check", json={"value": vpa}).json()
    return body["addresses"][0]["trust"]


def test_a_guest_draft_publishes_nothing(client: TestClient) -> None:
    before = standing(client, VICTIM)
    assert prepare_draft(client, VICTIM).status_code == 200
    after = standing(client, VICTIM)
    assert after["grade"] == before["grade"]
    assert after["reported_count"] == before["reported_count"]


def test_an_authenticated_draft_also_publishes_nothing(client: TestClient) -> None:
    """Gating on sign-in was not enough. An account is still only exploring."""
    registered = client.post(
        "/api/v1/auth/register",
        json={
            "email": "reviewer@example.com",
            "password": "review-passphrase-9",
            "display_name": "Reviewer",
        },
    )
    assert registered.status_code == 201, registered.text
    token = registered.json()["access_token"]

    before = standing(client, VICTIM)
    response = prepare_draft(
        client, VICTIM, headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 200
    after = standing(client, VICTIM)
    assert after["grade"] == before["grade"]
    assert after["reported_count"] == before["reported_count"]


def test_an_invalid_bearer_token_is_ignored_not_rejected(client: TestClient) -> None:
    """The draft is a safety screen; a bad header must not withhold it."""
    before = standing(client, VICTIM)
    response = prepare_draft(
        client, VICTIM, headers={"Authorization": "Bearer not-a-real-token"}
    )
    assert response.status_code == 200
    assert response.json()["report"]
    assert standing(client, VICTIM)["reported_count"] == before["reported_count"]


def test_a_draft_before_paying_publishes_nothing(client: TestClient) -> None:
    before = standing(client, VICTIM)
    response = prepare_draft(client, VICTIM, already_paid=False)
    assert response.status_code == 200
    assert standing(client, VICTIM)["reported_count"] == before["reported_count"]


def test_repeated_drafts_for_one_address_never_accumulate(client: TestClient) -> None:
    """Five separate assessments, five drafts, no change to what others see."""
    before = standing(client, VICTIM)
    for _ in range(5):
        assert prepare_draft(client, VICTIM).status_code == 200
    after = standing(client, VICTIM)
    assert after["reported_count"] == before["reported_count"]
    assert after["grade"] == before["grade"]
    assert after["score"] == before["score"]


def test_no_route_can_write_a_report_count(client: TestClient) -> None:
    """The publish path is gone, not merely unreachable from one endpoint."""
    from app.repositories import reputation_repository

    assert not hasattr(reputation_repository.ReputationRepository, "record_report")


# --------------------------------------------------------------------------
# 2. Standing escalates an unusual amount; it never discounts one
# --------------------------------------------------------------------------


def _trust(grade: TrustGrade) -> PayeeTrust:
    return PayeeTrust(
        vpa="merchant@okaxis",
        score=90,
        grade=grade,
        headline="Fixture",
        thin_file=False,
        impersonation=False,
        confidence="HIGH",
        pillars=[],
        assessed_points=0,
        assessable_maximum=1,
        first_seen_at=None,
        observed_days=400,
        check_count=500,
        distinct_device_count=200,
        reported_count=0,
        disclaimer="Fixture disclaimer.",
    )


def amount_weight(grade: TrustGrade, amount: str) -> int:
    result = RiskEngine().score(
        RiskInputs(
            payment=PaymentDetails(vpa="merchant@okaxis", amount=Decimal(amount)),
            known_payee=False,
            typical_amount=Decimal("100"),
            indicator=None,
            payee_trust=_trust(grade),
        )
    )
    return next(
        s.weight for s in result.signals if s.code == "AMOUNT_SCALED_BY_TRUST"
    )


@pytest.mark.parametrize("grade", list(TrustGrade))
@pytest.mark.parametrize("amount", ["4100.00", "9000.00", "25000.00", "250000.00"])
def test_standing_never_takes_an_amount_below_the_flat_baseline(
    grade: TrustGrade, amount: str
) -> None:
    assert amount_weight(grade, amount) >= WEIGHTS.unusual_amount


def test_the_best_grade_and_the_worst_bracket_the_same_baseline() -> None:
    """A to A+ is the boundary where a discount would have been largest."""
    best = amount_weight(TrustGrade.A_PLUS, "4100.00")
    good = amount_weight(TrustGrade.A, "4100.00")
    worst = amount_weight(TrustGrade.D, "4100.00")
    assert WEIGHTS.unusual_amount <= best <= good <= worst <= WEIGHTS.amount_scaled_by_trust


def test_a_huge_first_payment_to_a_top_rated_address_still_escalates() -> None:
    """The case the discount would have hidden: a large sum to a stranger.

    A+ standing describes the address, not this payment. The device has never
    paid it, and reputation that anyone could inflate must not quieten that.
    """
    weight = amount_weight(TrustGrade.A_PLUS, "500000.00")
    assert weight == WEIGHTS.amount_scaled_by_trust
    assert weight > WEIGHTS.unusual_amount


def test_consecutive_checks_do_not_move_the_amount_weight(client: TestClient) -> None:
    """One payer's repeated checks must not shift a third party's signal.

    Every check lands in the same ledger, so a signal read from that ledger
    can drift as the payer looks again. This walks the same request through
    six consecutive scores and asserts the verdict never changes.
    """
    parsed = client.post(
        "/api/v1/payments/parse",
        json={"upi_uri": "upi://pay?pa=steady.shop%40okaxis&am=9000&cu=INR"},
    ).json()
    observed = []
    for _ in range(6):
        body = client.post(
            "/api/v1/risk/score",
            json={"payment": parsed["payment"], "device_id": "repeat-device"},
        ).json()
        weight = next(
            (s["weight"] for s in body["signals"] if s["code"] == "AMOUNT_SCALED_BY_TRUST"),
            None,
        )
        observed.append((body["level"], weight))
    assert len({level for level, _ in observed}) == 1, observed
    assert all(weight >= WEIGHTS.unusual_amount for _, weight in observed), observed


# --------------------------------------------------------------------------
# 3. Exact band boundaries
# --------------------------------------------------------------------------


class _Boundary(RiskEngine):
    """An engine whose only signal is one weight we choose, to land on a band."""

    def score_exactly(self, points: int):
        from app.schemas import RiskAssessmentPayload, RiskSignal

        signals = [
            RiskSignal(
                code="TEST_BOUNDARY",
                label="Boundary probe",
                weight=points,
                evidence="Synthetic probe used to pin the band edges.",
            )
        ]
        return RiskAssessmentPayload(
            score=points,
            level=self._level(points),
            signals=signals,
            recommended_action=self._recommended_action(self._level(points)),
        )


@pytest.mark.parametrize(
    ("points", "expected"),
    [
        (0, RiskLevel.SAFE),
        (29, RiskLevel.SAFE),
        (30, RiskLevel.CAUTION),
        (69, RiskLevel.CAUTION),
        (70, RiskLevel.HIGH),
        (100, RiskLevel.HIGH),
    ],
)
def test_exact_band_edges(points: int, expected: RiskLevel) -> None:
    assert _Boundary()._level(points) is expected


def test_the_published_edges_are_the_edges_in_force() -> None:
    assert THRESHOLDS.safe_max == 29
    assert THRESHOLDS.caution_max == 69
