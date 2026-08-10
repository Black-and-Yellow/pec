from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


def test_health_and_parse_contract(client: TestClient) -> None:
    health = client.get("/api/v1/health")
    assert health.status_code == 200
    assert health.json()["database"] == "ok"
    assert health.json()["optional_ai"] == "disabled"
    assert health.headers["x-request-id"]

    parsed = client.post(
        "/api/v1/payments/parse",
        json={
            "upi_uri": (
                "upi://pay?pa=coffee.corner%40okaxis&pn=Coffee%20Corner&"
                "am=180.00&cu=INR&tn=Coffee"
            )
        },
    )
    assert parsed.status_code == 200
    assert parsed.json()["payment"]["vpa"] == "coffee.corner@okaxis"
    assert parsed.json()["payment"]["amount"] == 180.0
    assert parsed.json()["canonical_uri"].startswith("upi://pay?")


def test_actionable_parse_error(client: TestClient) -> None:
    response = client.post(
        "/api/v1/payments/parse", json={"upi_uri": "upi://pay?am=100"}
    )
    assert response.status_code == 422
    assert response.json()["error"] == {
        "code": "MISSING_VPA",
        "message": "The UPI payment request is missing the payee VPA",
    }


def test_framework_http_errors_use_the_safe_api_error_envelope(client: TestClient) -> None:
    missing = client.get("/api/v1/not-a-route")
    assert missing.status_code == 404
    assert missing.json() == {"error": {"code": "HTTP_404", "message": "Not Found"}}

    wrong_method = client.get("/api/v1/risk/score")
    assert wrong_method.status_code == 405
    assert wrong_method.headers["allow"] == "POST"
    assert wrong_method.json()["error"]["code"] == "HTTP_405"


def test_all_demo_scenarios_are_stable_and_repeatable(client: TestClient) -> None:
    scenarios_response = client.get("/api/v1/demo/scenarios")
    assert scenarios_response.status_code == 200
    scenarios = scenarios_response.json()["scenarios"]
    assert [scenario["expected_level"] for scenario in scenarios] == [
        "SAFE",
        "CAUTION",
        "HIGH",
    ]
    expected_policies = {
        "SAFE": ("NORMAL", False),
        "CAUTION": ("DELIBERATE_CONFIRMATION", True),
        "HIGH": ("PAUSED", True),
    }

    for _ in range(2):
        for scenario in scenarios:
            parsed = client.post(
                "/api/v1/payments/parse", json={"upi_uri": scenario["upi_uri"]}
            ).json()["payment"]
            scored = client.post(
                "/api/v1/risk/score",
                json={
                    "payment": parsed,
                    "device_id": scenario["device_id"],
                    "context": scenario["context"],
                },
            )
            assert scored.status_code == 200, scored.text
            result = scored.json()
            assert result["level"] == scenario["expected_level"]
            assert result["score"] == scenario["expected_score"]
            policy, requires_confirmation = expected_policies[result["level"]]
            assert result["handoff_policy"] == policy
            assert result["requires_confirmation"] is requires_confirmation


def test_high_risk_response_requires_human_control(client: TestClient) -> None:
    scenario = client.get("/api/v1/demo/scenarios").json()["scenarios"][2]
    payment = client.post(
        "/api/v1/payments/parse", json={"upi_uri": scenario["upi_uri"]}
    ).json()["payment"]
    assessment = client.post(
        "/api/v1/risk/score",
        json={
            "payment": payment,
            "device_id": scenario["device_id"],
            "context": scenario["context"],
        },
    ).json()

    prepared = client.post(
        "/api/v1/response/prepare",
        json={
            "payment": payment,
            "assessment": assessment,
            "context": scenario["context"],
            "suspicious_message": "Urgent KYC update requested",
            "already_paid": True,
        },
    )
    assert prepared.status_code == 200, prepared.text
    body = prepared.json()
    assert body["mode"] == "RECOVERY"
    assert "HIGH RISK" in body["summary"]
    assert body["external_actions_performed"] is False
    assert body["report"]["context_signals"] == scenario["context"]
    assert body["report"]["transaction_note"] == "Urgent KYC account block"
    assert "payment request note was: Urgent KYC account block" in body["report"]["summary"]
    external_actions = [action for action in body["actions"] if action["external_target"]]
    assert external_actions
    assert all(action["requires_confirmation"] for action in external_actions)
    assert "cannot freeze, reverse, cancel" in body["disclaimer"]


def test_history_contains_assessments_without_changing_completed_history(
    client: TestClient,
) -> None:
    payment = {
        "vpa": "first.time@upi",
        "payee_name": "First Time",
        "amount": 4500,
        "transaction_note": "Order payment",
        "currency": "INR",
        "transaction_reference": None,
    }
    first = client.post(
        "/api/v1/risk/score", json={"payment": payment, "device_id": "history-device"}
    ).json()
    second = client.post(
        "/api/v1/risk/score", json={"payment": payment, "device_id": "history-device"}
    ).json()
    assert first["score"] == second["score"] == 33

    history = client.get("/api/v1/history", params={"device_id": "history-device"})
    assert history.status_code == 200
    assert history.json()["count"] == 2
    assert all(item["assessed_at"].endswith("Z") for item in history.json()["items"])


def test_context_without_key_is_graceful(client: TestClient) -> None:
    response = client.post(
        "/api/v1/context/analyze",
        json={
            "text": "Urgent KYC payment required now",
            "consent_to_external_ai": True,
        },
    )
    assert response.status_code == 200
    assert response.json()["available"] is False
    assert response.json()["status"] == "ai_disabled"
    assert response.json()["context"]["urgency"] is True


def test_validation_error_does_not_echo_sensitive_input(client: TestClient) -> None:
    sensitive_marker = "DO-NOT-ECHO-THIS-UPLOAD"
    response = client.post(
        "/api/v1/context/analyze",
        json={"screenshot_base64": sensitive_marker, "screenshot_mime_type": "image/png"},
    )
    assert response.status_code == 422
    assert sensitive_marker not in response.text


def test_context_contract_does_not_coerce_consent_strings(client: TestClient) -> None:
    response = client.post(
        "/api/v1/context/analyze",
        json={"text": "Pay now", "consent_to_external_ai": "true"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_prepare_response_requires_a_server_assessment(client: TestClient) -> None:
    response = client.post(
        "/api/v1/response/prepare",
        json={
            "payment": {"vpa": "person@upi", "amount": 100, "currency": "INR"},
            "assessment": {
                "score": 0,
                "level": "SAFE",
                "signals": [],
                "recommended_action": "Continue",
            },
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "ASSESSMENT_ID_REQUIRED"


def test_prepare_response_rejects_payment_mismatch_and_ignores_score_tampering(
    client: TestClient,
) -> None:
    payment = {
        "vpa": "market.seller@okaxis",
        "payee_name": "Marketplace Seller",
        "amount": 4500,
        "transaction_note": "Order payment",
        "currency": "INR",
        "transaction_reference": None,
    }
    assessment = client.post(
        "/api/v1/risk/score",
        json={"payment": payment, "device_id": "response-device"},
    ).json()
    tampered = assessment | {
        "score": 0,
        "level": "SAFE",
        "signals": [],
        "recommended_action": "Skip the warning",
    }

    mismatch = client.post(
        "/api/v1/response/prepare",
        json={
            "payment": payment | {"amount": 1},
            "assessment": tampered,
            "already_paid": True,
        },
    )
    assert mismatch.status_code == 409
    assert mismatch.json()["error"]["code"] == "ASSESSMENT_PAYMENT_MISMATCH"

    prepared = client.post(
        "/api/v1/response/prepare",
        json={"payment": payment, "assessment": tampered, "already_paid": True},
    )
    assert prepared.status_code == 200
    assert prepared.json()["report"]["risk_score"] == 33
    assert prepared.json()["report"]["risk_level"] == "CAUTION"


def test_health_returns_service_unavailable_when_database_check_fails(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(client.app.state.database, "is_healthy", lambda: False)
    response = client.get("/api/v1/health")
    assert response.status_code == 503
    assert response.json()["status"] == "degraded"
    assert response.json()["database"] == "unavailable"
