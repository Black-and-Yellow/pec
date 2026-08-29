from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.integrations.gemini_client import GeminiClient
from app.main import create_app


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
                "upi://pay?pa=coffee.corner%40okaxis&pn=Coffee%20Corner&am=180.00&cu=INR&tn=Coffee"
            )
        },
    )
    assert parsed.status_code == 200
    assert parsed.json()["payment"]["vpa"] == "coffee.corner@okaxis"
    assert parsed.json()["payment"]["amount"] == 180.0
    assert parsed.json()["canonical_uri"].startswith("upi://pay?")


def test_actionable_parse_error(client: TestClient) -> None:
    response = client.post("/api/v1/payments/parse", json={"upi_uri": "upi://pay?am=100"})
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


def test_risk_score_requires_an_explicit_device_capability(client: TestClient) -> None:
    schema = client.get("/openapi.json").json()
    required_fields = schema["components"]["schemas"]["RiskScoreRequest"]["required"]
    assert "device_id" in required_fields

    payment = client.post(
        "/api/v1/payments/parse",
        json={"upi_uri": "upi://pay?pa=explicit.device%40upi&am=10&cu=INR"},
    ).json()["payment"]
    response = client.post("/api/v1/risk/score", json={"payment": payment})

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"
    assert any(
        field["location"] == "body.device_id" and field["type"] == "missing"
        for field in response.json()["error"]["fields"]
    )


def test_all_demo_scenarios_are_stable_and_repeatable(client: TestClient) -> None:
    scenarios_response = client.get("/api/v1/demo/scenarios")
    assert scenarios_response.status_code == 200
    scenarios = scenarios_response.json()["scenarios"]
    assert [scenario["id"] for scenario in scenarios] == [
        "coffee-shop",
        "tea-stall",
        "marketplace-seller",
        "fake-kyc",
    ]
    # The frozen demo metadata is synchronized by the human after backend and
    # Flutter score changes land together. Keep the backend handoff explicit.
    expected_results = {
        "coffee-shop": ((0, 0), "SAFE"),
        "tea-stall": ((23, 23), "SAFE"),
        # Payee history legitimately improves trust after the first assessment.
        "marketplace-seller": ((27, 24), "SAFE"),
        "fake-kyc": ((100, 100), "HIGH"),
    }

    expected_policies = {
        "SAFE": ("NORMAL", False),
        "HIGH": ("PAUSED", True),
    }

    for pass_index in range(2):
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
                    "context_token": scenario["context_token"],
                },
            )
            assert scored.status_code == 200, scored.text
            result = scored.json()
            expected_scores, expected_level = expected_results[scenario["id"]]
            assert result["level"] == expected_level
            assert result["score"] == expected_scores[pass_index]
            policy, requires_confirmation = expected_policies[result["level"]]
            assert result["handoff_policy"] == policy
            assert result["requires_confirmation"] is requires_confirmation


def test_high_risk_response_requires_human_control(client: TestClient) -> None:
    scenarios = client.get("/api/v1/demo/scenarios").json()["scenarios"]
    scenario = next(item for item in scenarios if item["id"] == "fake-kyc")
    payment = client.post("/api/v1/payments/parse", json={"upi_uri": scenario["upi_uri"]}).json()[
        "payment"
    ]
    assessment = client.post(
        "/api/v1/risk/score",
        json={
            "payment": payment,
            "device_id": scenario["device_id"],
            "context": scenario["context"],
            "context_token": scenario["context_token"],
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
    assert first["score"] == second["score"] == 32

    history = client.get("/api/v1/history", headers={"X-FinGuard-Device-ID": "history-device"})
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
    assert response.json()["context_token"]


def test_risk_explain_returns_template_for_a_stored_assessment_when_ai_is_off(
    client: TestClient,
) -> None:
    scored = client.post(
        "/api/v1/risk/score",
        json={
            "payment": {
                "vpa": "explain.person@upi",
                "amount": 100,
                "currency": "INR",
            },
            "device_id": "explain-device",
        },
    )
    assessment_id = scored.json()["assessment_id"]

    response = client.post(
        "/api/v1/risk/explain",
        json={
            "assessment_id": assessment_id,
            "consent_to_external_ai": True,
        },
    )

    assert response.status_code == 200
    assert response.json()["source"] == "template"
    assert response.json()["status"] == "ai_disabled"
    assert response.json()["available"] is True
    assert "FinGuard rated this " in response.json()["explanation"]
    assert " because" in response.json()["explanation"]


def test_risk_explain_rejects_an_unknown_assessment(client: TestClient) -> None:
    response = client.post(
        "/api/v1/risk/explain",
        json={
            "assessment_id": "missing-assessment",
            "consent_to_external_ai": False,
        },
    )

    assert response.status_code == 404
    assert response.json() == {
        "error": {
            "code": "ASSESSMENT_NOT_FOUND",
            "message": "The requested risk assessment was not found",
        }
    }


@pytest.mark.parametrize(
    "body",
    [
        {
            "assessment_id": "missing-assessment",
            "consent_to_external_ai": "true",
        },
        {
            "assessment_id": "missing-assessment",
            "consent_to_external_ai": False,
            "score": 0,
        },
    ],
)
def test_risk_explain_request_is_strict(
    client: TestClient,
    body: dict[str, object],
) -> None:
    response = client.post("/api/v1/risk/explain", json=body)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"


def test_risk_explain_falls_back_when_gemini_wording_is_malformed(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def contradict_assessment(
        _: GeminiClient,
        **__: object,
    ) -> str:
        return "This request is safe."

    monkeypatch.setattr(
        GeminiClient,
        "explain_assessment",
        contradict_assessment,
    )
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{(tmp_path / 'explain-test.db').as_posix()}",
        allowed_origins=(),
        gemini_api_key="test-only-provider-key",
        enable_ai_context=True,
    )
    with TestClient(create_app(settings)) as ai_client:
        scored = ai_client.post(
            "/api/v1/risk/score",
            json={
                "payment": {
                    "vpa": "explain.person@upi",
                    "amount": 4500,
                    "currency": "INR",
                },
                "device_id": "explain-device",
            },
        )
        before = scored.json()
        response = ai_client.post(
            "/api/v1/risk/explain",
            json={
                "assessment_id": before["assessment_id"],
                "consent_to_external_ai": True,
            },
        )

    assert response.status_code == 200
    assert response.json()["source"] == "template"
    assert response.json()["status"] == "malformed_response"
    assert "rated this " in response.json()["explanation"]
    assert before["score"] == 32
    assert before["level"] == "CAUTION"


def test_source_none_context_response_has_no_integrity_token(client: TestClient) -> None:
    response = client.post(
        "/api/v1/context/analyze",
        json={
            "screenshot_base64": "iVBORw0KGgo=",
            "screenshot_mime_type": "image/png",
            "consent_to_external_ai": False,
        },
    )
    assert response.status_code == 200
    assert response.json()["source"] == "none"
    assert "context_token" not in response.json()


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
    assert prepared.json()["report"]["risk_score"] == 26
    assert prepared.json()["report"]["risk_level"] == "SAFE"


def test_health_returns_service_unavailable_when_database_check_fails(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(client.app.state.database, "is_healthy", lambda: False)
    response = client.get("/api/v1/health")
    assert response.status_code == 503
    assert response.json()["status"] == "degraded"
    assert response.json()["database"] == "unavailable"
