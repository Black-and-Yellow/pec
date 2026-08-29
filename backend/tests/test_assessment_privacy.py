from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

import app.main as main_module
from app.config import Settings
from app.db.models import RiskAssessment, RiskSignalRecord, Transaction
from app.main import create_app
from app.repositories.transaction_repository import hash_device_identifier

HISTORY_DEVICE_HEADER = "X-FinGuard-Device-ID"
PAYMENT = {
    "vpa": "privacy.test@upi",
    "payee_name": "Privacy Test",
    "amount": 125,
    "transaction_note": "Synthetic test",
    "currency": "INR",
    "transaction_reference": None,
}


def _score(client: TestClient, device_id: str) -> dict[str, object]:
    response = client.post(
        "/api/v1/risk/score",
        json={"payment": PAYMENT, "device_id": device_id},
    )
    assert response.status_code == 200, response.text
    return response.json()


def _add_legacy_assessment(
    session: Session,
    *,
    transaction_id: str,
    assessment_id: str,
    device_id: str,
    created_at: datetime,
) -> None:
    transaction = Transaction(
        id=transaction_id,
        device_id=device_id,
        vpa="legacy.test@upi",
        amount=Decimal("75.00"),
        currency="INR",
        status="ASSESSED",
        source="PRE_HASH_TEST_FIXTURE",
        created_at=created_at,
    )
    assessment = RiskAssessment(
        id=assessment_id,
        transaction=transaction,
        score=33,
        level="CAUTION",
        recommended_action="Verify independently.",
        created_at=created_at,
    )
    assessment.signals = [
        RiskSignalRecord(
            position=0,
            code="UNKNOWN_PAYEE",
            label="First payment to this payee",
            weight=33,
            evidence="No prior completed payment was found for this device.",
        )
    ]
    session.add(assessment)
    session.commit()


def test_history_requires_valid_header_capability(client: TestClient) -> None:
    device_id = "history-header-device"
    _score(client, device_id)

    missing = client.get("/api/v1/history")
    assert missing.status_code == 422
    assert missing.json()["error"]["code"] == "VALIDATION_ERROR"

    query_only = client.get("/api/v1/history", params={"device_id": device_id})
    assert query_only.status_code == 422
    assert query_only.json()["error"]["code"] == "VALIDATION_ERROR"
    assert device_id not in query_only.text

    malformed_value = "not a valid device capability"
    malformed = client.get(
        "/api/v1/history", headers={HISTORY_DEVICE_HEADER: malformed_value}
    )
    assert malformed.status_code == 422
    assert malformed.json()["error"]["code"] == "VALIDATION_ERROR"
    assert malformed_value not in malformed.text

    history = client.get(
        "/api/v1/history",
        headers={HISTORY_DEVICE_HEADER: device_id},
        params={"device_id": "ignored-query-capability"},
    )
    assert history.status_code == 200
    assert history.json()["count"] == 1
    assert device_id not in history.text


def test_new_device_identifiers_are_hashed_and_legacy_rows_remain_readable(
    client: TestClient,
) -> None:
    new_device_id = "new-private-device"
    scored = _score(client, new_device_id)

    with client.app.state.database.session() as session:
        stored = session.get(Transaction, scored["transaction_id"])
        assert stored is not None
        assert stored.device_id == hash_device_identifier(new_device_id)
        assert stored.device_id != new_device_id
        assert "$" in stored.device_id
        assert (
            session.scalar(
                select(func.count(Transaction.id)).where(
                    Transaction.device_id == new_device_id
                )
            )
            == 0
        )

        legacy_device_id = "legacy-readable-device"
        _add_legacy_assessment(
            session,
            transaction_id="legacy-readable-transaction",
            assessment_id="legacy-readable-assessment",
            device_id=legacy_device_id,
            created_at=datetime.now(UTC) - timedelta(minutes=5),
        )

    current = _score(client, legacy_device_id)
    history = client.get(
        "/api/v1/history", headers={HISTORY_DEVICE_HEADER: legacy_device_id}
    )
    assert history.status_code == 200
    assert {item["assessment_id"] for item in history.json()["items"]} == {
        "legacy-readable-assessment",
        current["assessment_id"],
    }


def test_scoring_enforces_expiry_and_budgets_without_process_restart(
    client: TestClient,
) -> None:
    original_settings = client.app.state.settings
    client.app.state.settings = replace(
        original_settings,
        assessment_retention_days=1,
        max_assessed_records_total=3,
        max_assessed_records_per_device=2,
    )
    try:
        with client.app.state.database.session() as session:
            completed_before = session.scalar(
                select(func.count(Transaction.id)).where(Transaction.status == "COMPLETED")
            )
            _add_legacy_assessment(
                session,
                transaction_id="expired-while-running-transaction",
                assessment_id="expired-while-running-assessment",
                device_id="expired-while-running-device",
                created_at=datetime.now(UTC) - timedelta(days=2),
            )
            _add_legacy_assessment(
                session,
                transaction_id="legacy-quota-transaction",
                assessment_id="legacy-quota-assessment",
                device_id="quota-device-a",
                created_at=datetime.now(UTC) - timedelta(minutes=10),
            )

        results_a = [_score(client, "quota-device-a") for _ in range(3)]
        results_b = [_score(client, "quota-device-b") for _ in range(2)]

        with client.app.state.database.session() as session:
            assert session.get(Transaction, "expired-while-running-transaction") is None
            assert session.get(RiskAssessment, "expired-while-running-assessment") is None
            assert session.get(Transaction, "legacy-quota-transaction") is None

            assessed_total = session.scalar(
                select(func.count(Transaction.id)).where(Transaction.status == "ASSESSED")
            )
            assert assessed_total == 3
            for device_id in ("quota-device-a", "quota-device-b"):
                stored_keys = (hash_device_identifier(device_id), device_id)
                device_count = session.scalar(
                    select(func.count(Transaction.id)).where(
                        Transaction.status == "ASSESSED",
                        Transaction.device_id.in_(stored_keys),
                    )
                )
                assert device_count is not None
                assert device_count <= 2

            completed_after = session.scalar(
                select(func.count(Transaction.id)).where(Transaction.status == "COMPLETED")
            )
            assert completed_after == completed_before
            assert session.get(RiskAssessment, results_a[0]["assessment_id"]) is None
            assert session.get(RiskAssessment, results_b[-1]["assessment_id"]) is not None
    finally:
        client.app.state.settings = original_settings


def test_expired_assessment_is_unavailable_to_history_and_response(
    client: TestClient,
) -> None:
    device_id = "expired-read-boundary-device"
    expired_payment = PAYMENT | {
        "amount": 127,
        "transaction_reference": "expired-private-reference-987",
    }
    scored_response = client.post(
        "/api/v1/risk/score",
        json={"payment": expired_payment, "device_id": device_id},
    )
    assert scored_response.status_code == 200, scored_response.text
    scored = scored_response.json()
    expired_at = datetime.now(UTC) - timedelta(days=31)

    with client.app.state.database.session() as session:
        transaction = session.get(Transaction, scored["transaction_id"])
        assessment = session.get(RiskAssessment, scored["assessment_id"])
        assert transaction is not None
        assert assessment is not None
        transaction.created_at = expired_at
        assessment.created_at = expired_at
        session.commit()

    history = client.get(
        "/api/v1/history",
        headers={HISTORY_DEVICE_HEADER: device_id},
    )
    assert history.status_code == 200
    assert history.json() == {"items": [], "count": 0}
    for sensitive_value in (
        expired_payment["vpa"],
        expired_payment["payee_name"],
        expired_payment["transaction_note"],
        expired_payment["transaction_reference"],
        "127.0",
    ):
        assert sensitive_value not in history.text

    prepared = client.post(
        "/api/v1/response/prepare",
        json={"payment": expired_payment, "assessment": scored, "already_paid": True},
    )
    assert prepared.status_code == 404
    assert prepared.json()["error"]["code"] == "ASSESSMENT_NOT_FOUND"
    for sensitive_value in (
        expired_payment["vpa"],
        expired_payment["payee_name"],
        expired_payment["transaction_note"],
        expired_payment["transaction_reference"],
        "127.0",
    ):
        assert sensitive_value not in prepared.text

    with client.app.state.database.session() as session:
        assert session.get(Transaction, scored["transaction_id"]) is not None


def test_periodic_cleanup_deletes_expired_assessed_rows_without_new_score_or_restart(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(main_module, "_ASSESSMENT_CLEANUP_INTERVAL_SECONDS", 0.02)
    database_path = (tmp_path / "periodic-retention.db").as_posix()
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{database_path}",
        allowed_origins=(),
        assessment_retention_days=1,
    )

    with TestClient(create_app(settings)) as test_client:
        with test_client.app.state.database.session() as session:
            completed_ids = set(
                session.scalars(
                    select(Transaction.id).where(Transaction.status == "COMPLETED")
                )
            )
            assert completed_ids
            _add_legacy_assessment(
                session,
                transaction_id="periodic-expired-transaction",
                assessment_id="periodic-expired-assessment",
                device_id="periodic-expired-device",
                created_at=datetime.now(UTC) - timedelta(days=2),
            )

        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            with test_client.app.state.database.session() as session:
                if session.get(Transaction, "periodic-expired-transaction") is None:
                    break
            time.sleep(0.01)
        else:
            pytest.fail("periodic cleanup did not delete the expired assessment")

        with test_client.app.state.database.session() as session:
            assert session.get(RiskAssessment, "periodic-expired-assessment") is None
            assert set(
                session.scalars(
                    select(Transaction.id).where(Transaction.status == "COMPLETED")
                )
            ) == completed_ids


def test_concurrent_scoring_preserves_the_per_device_budget(client: TestClient) -> None:
    original_settings = client.app.state.settings
    client.app.state.settings = replace(
        original_settings,
        max_assessed_records_total=3,
        max_assessed_records_per_device=2,
    )
    try:
        with ThreadPoolExecutor(max_workers=4) as executor:
            responses = list(
                executor.map(
                    lambda _: client.post(
                        "/api/v1/risk/score",
                        json={"payment": PAYMENT, "device_id": "concurrent-device"},
                    ),
                    range(8),
                )
            )
        assert all(response.status_code == 200 for response in responses)

        with client.app.state.database.session() as session:
            stored_keys = (
                hash_device_identifier("concurrent-device"),
                "concurrent-device",
            )
            assert (
                session.scalar(
                    select(func.count(Transaction.id)).where(
                        Transaction.status == "ASSESSED",
                        Transaction.device_id.in_(stored_keys),
                    )
                )
                == 2
            )
            assert (
                session.scalar(
                    select(func.count(Transaction.id)).where(
                        Transaction.status == "ASSESSED"
                    )
                )
                <= 3
            )
    finally:
        client.app.state.settings = original_settings
