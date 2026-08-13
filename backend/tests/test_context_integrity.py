from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta
from io import StringIO
from typing import Any

import jwt
import pytest
from fastapi.testclient import TestClient


def _coffee_payment(client: TestClient) -> dict[str, Any]:
    scenario = client.get("/api/v1/demo/scenarios").json()["scenarios"][0]
    response = client.post(
        "/api/v1/payments/parse", json={"upi_uri": scenario["upi_uri"]}
    )
    assert response.status_code == 200
    return response.json()["payment"]


def _local_analysis(client: TestClient) -> dict[str, Any]:
    response = client.post(
        "/api/v1/context/analyze",
        json={
            "text": "Urgent KYC payment required now",
            "consent_to_external_ai": False,
        },
    )
    assert response.status_code == 200
    result = response.json()
    assert result["source"] == "local_rules"
    assert result["context_token"]
    claims = jwt.decode(result["context_token"], options={"verify_signature": False})
    assert claims["source"] == "local_rules"
    return result


def _score(
    client: TestClient,
    *,
    context: dict[str, Any] | None = None,
    context_token: str | None = None,
):
    return client.post(
        "/api/v1/risk/score",
        json={
            "payment": _coffee_payment(client),
            "device_id": "demo-device",
            **({"context": context} if context is not None else {}),
            **({"context_token": context_token} if context_token is not None else {}),
        },
    )


def test_valid_local_analysis_token_is_the_only_context_used_for_score(
    client: TestClient,
) -> None:
    baseline = _score(client)
    assert baseline.status_code == 200
    assert baseline.json()["score"] == 0

    analysis = _local_analysis(client)
    scored = _score(
        client,
        context=analysis["context"],
        context_token=analysis["context_token"],
    )
    assert scored.status_code == 200
    assert scored.json()["score"] == 18
    assert {signal["code"] for signal in scored.json()["signals"]} == {
        "CONTEXT_URGENCY",
        "CONTEXT_KYC_THREAT",
    }


def test_unsigned_or_unpaired_context_is_rejected(client: TestClient) -> None:
    analysis = _local_analysis(client)
    unsigned = _score(client, context=analysis["context"])
    token_only = _score(client, context_token=analysis["context_token"])

    for response in (unsigned, token_only):
        assert response.status_code == 422
        assert response.json() == {
            "error": {
                "code": "INVALID_CONTEXT_INTEGRITY",
                "message": "Context must come from a current FinGuard analysis",
            }
        }


def test_one_bit_context_mismatch_is_rejected(client: TestClient) -> None:
    analysis = _local_analysis(client)
    mismatched = analysis["context"] | {
        "urgency": not analysis["context"]["urgency"]
    }

    response = _score(
        client,
        context=mismatched,
        context_token=analysis["context_token"],
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "INVALID_CONTEXT_INTEGRITY"
    assert analysis["context_token"] not in response.text


@pytest.mark.parametrize(
    "variant",
    [
        "expired",
        "future_issued",
        "excessive_lifetime",
        "wrong_audience",
        "wrong_type",
        "wrong_algorithm",
        "missing_provenance",
        "wrong_provenance",
        "unsupported_score_claim",
        "context_verdict_claim",
        "malformed",
    ],
)
def test_invalid_context_tokens_are_rejected_without_echo(
    client: TestClient, variant: str
) -> None:
    analysis = _local_analysis(client)
    token = analysis["context_token"]
    marker = "DO-NOT-ECHO-CONTEXT-TOKEN"
    if variant == "malformed":
        invalid_token = marker
    else:
        claims = jwt.decode(token, options={"verify_signature": False})
        algorithm = "HS256"
        if variant == "expired":
            issued_at = datetime.now(UTC) - timedelta(minutes=10)
            claims["iat"] = issued_at
            claims["exp"] = issued_at + timedelta(minutes=5)
        elif variant == "future_issued":
            issued_at = datetime.now(UTC) + timedelta(minutes=10)
            claims["iat"] = issued_at
            claims["exp"] = issued_at + timedelta(minutes=5)
        elif variant == "excessive_lifetime":
            issued_at = datetime.now(UTC)
            claims["iat"] = issued_at
            claims["exp"] = issued_at + timedelta(seconds=301)
        elif variant == "wrong_audience":
            claims["aud"] = "not-finguard-risk"
        elif variant == "wrong_type":
            claims["type"] = "access"
        elif variant == "wrong_algorithm":
            algorithm = "HS384"
        elif variant == "missing_provenance":
            claims.pop("source")
        elif variant == "wrong_provenance":
            claims["source"] = "untrusted_client"
        elif variant == "unsupported_score_claim":
            claims["score"] = 100
        elif variant == "context_verdict_claim":
            claims["context"] = claims["context"] | {"verdict": "SAFE"}
        invalid_token = jwt.encode(
            claims,
            client.app.state.settings.auth_secret_key,
            algorithm=algorithm,
        )

    response = _score(
        client,
        context=analysis["context"],
        context_token=invalid_token,
    )

    assert response.status_code == 422
    assert response.json() == {
        "error": {
            "code": "INVALID_CONTEXT_INTEGRITY",
            "message": "Context must come from a current FinGuard analysis",
        }
    }
    assert invalid_token not in response.text
    assert marker not in response.text


def test_demo_context_token_binds_seeded_provenance(client: TestClient) -> None:
    scenario = client.get("/api/v1/demo/scenarios").json()["scenarios"][2]

    claims = jwt.decode(scenario["context_token"], options={"verify_signature": False})

    assert claims["source"] == "demo"
    assert claims["context"] == scenario["context"]
    assert "score" not in claims
    assert "level" not in claims
    assert "verdict" not in claims


def test_invalid_context_does_not_log_token_or_payment_data(client: TestClient) -> None:
    token_marker = "DO-NOT-LOG-CONTEXT-TOKEN"
    payment_marker = "DO-NOT-LOG-PAYMENT-NOTE"
    output = StringIO()
    handler = logging.StreamHandler(output)
    logger = logging.getLogger("finguard")
    logger.addHandler(handler)
    try:
        response = client.post(
            "/api/v1/risk/score",
            json={
                "payment": {
                    "vpa": "privacy.marker@upi",
                    "amount": 1,
                    "currency": "INR",
                    "transaction_note": payment_marker,
                },
                "device_id": "privacy-device",
                "context": {
                    "impersonation": False,
                    "urgency": False,
                    "kyc_threat": False,
                    "reward_or_refund_claim": False,
                    "payment_requested": False,
                    "suspicious_support_claim": False,
                    "confidence": 0.0,
                },
                "context_token": token_marker,
            },
        )
    finally:
        logger.removeHandler(handler)

    assert response.status_code == 422
    logs = output.getvalue()
    assert token_marker not in logs
    assert payment_marker not in logs
    assert "privacy.marker@upi" not in logs
