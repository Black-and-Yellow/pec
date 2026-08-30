"""Milestone 1: what FinGuard may claim, and who may change a shared grade.

These are wording and authority tests. They exist because the failure mode is
not a crash: it is a sentence that sounds like bank data, or a stranger able
to brand somebody else's address, and neither shows up in a functional test.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.repositories.reputation_repository import unknown_snapshot
from app.schemas import EvidenceProvenance, TrustPillarCode
from app.services import mule_signature
from app.services.trust_score import TrustInputs, TrustScorer

# Words that assert a view of money movement FinGuard does not have.
FORBIDDEN = ("payers", "people have paid", "money collected", "transaction traffic")


def all_evidence_text(vpa: str) -> str:
    report = TrustScorer().score(TrustInputs(vpa=vpa, reputation=unknown_snapshot(vpa)))
    parts = [report.headline, report.disclaimer]
    parts += [p.evidence for p in report.pillars]
    parts += [p.label for p in report.pillars]
    return " ".join(parts).lower()


@pytest.mark.parametrize("vpa", ["coffee.corner@okaxis", "sbi-refund@okaxis", "new.shop@ybl"])
def test_a_trust_report_never_claims_to_have_seen_a_payment(vpa: str) -> None:
    text = all_evidence_text(vpa)
    for word in FORBIDDEN:
        assert word not in text, f"{vpa} evidence claims '{word}'"


def test_the_mule_evidence_is_labelled_as_check_data(client: TestClient) -> None:
    body = client.post("/api/v1/trust/check", json={"value": "rahul.sharma91@ybl"})
    summary = body.json()["summary"]
    assert "not bank transaction data" in summary
    for word in FORBIDDEN:
        assert word not in summary.lower()


def test_the_identity_pillar_is_marked_as_read_on_this_device() -> None:
    """It needs no lookup, so claiming it as network evidence would inflate it."""
    report = TrustScorer().score(
        TrustInputs(vpa="shop@okaxis", reputation=unknown_snapshot("shop@okaxis"))
    )
    identity = next(p for p in report.pillars if p.code is TrustPillarCode.IDENTITY)
    assert identity.provenance is EvidenceProvenance.DEVICE_LOCAL


def test_a_seeded_match_is_labelled_as_demo_data(client: TestClient) -> None:
    body = client.post("/api/v1/trust/check", json={"value": "secure-kyc-update@okaxis"})
    pillars = body.json()["addresses"][0]["trust"]["pillars"]
    conduct = next(p for p in pillars if p["code"] == "CONDUCT")
    assert conduct["provenance"] == EvidenceProvenance.SEEDED_DEMO.value
    assert "seeded demo" in conduct["evidence"].lower()


def test_a_mobile_lookup_does_not_claim_to_identify_the_owner(client: TestClient) -> None:
    body = client.post("/api/v1/trust/check", json={"value": "9000000001"}).json()
    summary = body["summary"].lower()
    assert "phone-shaped upi addresses" in summary
    assert "cannot look up who owns a number" in summary
    # Silence about a number must never be reported as safety.
    assert "not a clean bill of health" in summary


def test_a_known_number_still_disclaims_ownership(client: TestClient) -> None:
    body = client.post("/api/v1/trust/check", json={"value": "9182736450"}).json()
    assert "does not identify who owns the number" in body["summary"]


def test_the_disclaimer_names_the_source_of_the_grade() -> None:
    report = TrustScorer().score(
        TrustInputs(vpa="shop@okaxis", reputation=unknown_snapshot("shop@okaxis"))
    )
    lowered = report.disclaimer.lower()
    assert "not an npci, bank, or credit bureau rating" in lowered


def test_mule_signature_reports_check_sources_not_payers() -> None:
    from datetime import UTC, datetime, timedelta

    from app.repositories.reputation_repository import ReputationSnapshot

    now = datetime.now(UTC)
    shape = mule_signature.assess(
        ReputationSnapshot(
            vpa="x@y",
            first_seen_at=now - timedelta(days=5),
            last_seen_at=now,
            check_count=40,
            distinct_device_count=38,
            safe_count=0,
            caution_count=5,
            high_count=30,
            reported_count=0,
            recent_new_device_count=36,
        )
    )
    assert shape.matched is True
    assert shape.check_source_count == 38
    assert "independent checks" in shape.evidence


def _score_and_report(client: TestClient, vpa: str, headers: dict | None = None):
    """Score a payment to `vpa`, then prepare an incident report for it."""
    parsed = client.post(
        "/api/v1/payments/parse",
        json={"upi_uri": f"upi://pay?pa={vpa.replace('@', '%40')}&am=500&cu=INR"},
    ).json()
    scored = client.post(
        "/api/v1/risk/score",
        json={"payment": parsed["payment"], "device_id": "attacker-device"},
    ).json()
    prepared = client.post(
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
            "already_paid": False,
        },
        headers=headers or {},
    )
    return prepared


def grade_of(client: TestClient, vpa: str) -> str:
    body = client.post("/api/v1/trust/check", json={"value": vpa}).json()
    return body["addresses"][0]["trust"]["grade"]


def test_an_anonymous_report_cannot_brand_someone_elses_address(
    client: TestClient,
) -> None:
    """Two requests must not be enough to cap a stranger's public grade.

    Nothing stops an anonymous caller from scoring a payment to any address
    and immediately reporting it. If that counted, one person could push a
    rival's VPA to the bottom band for everyone who ever checks it.
    """
    victim = "honest.baker@okhdfcbank"
    before = grade_of(client, victim)

    prepared = _score_and_report(client, victim)
    # The user still gets their draft: the recovery steps are the point.
    assert prepared.status_code == 200
    assert prepared.json()["report"]

    assert grade_of(client, victim) == before


def test_the_report_draft_is_still_produced_for_a_guest(client: TestClient) -> None:
    prepared = _score_and_report(client, "some.stall@okaxis")
    assert prepared.status_code == 200
    assert "report" in prepared.json()
