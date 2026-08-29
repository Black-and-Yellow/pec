from __future__ import annotations

import httpx


def test_live_uvicorn_health_parse_errors_and_demo_risk_results(
    live_api_url: str,
) -> None:
    with httpx.Client(base_url=live_api_url, timeout=5, trust_env=False) as client:
        health = client.get("/api/v1/health")
        assert health.status_code == 200
        assert health.json()["database"] == "ok"
        assert health.json()["optional_ai"] == "disabled"

        parsed = client.post(
            "/api/v1/payments/parse",
            json={
                "upi_uri": (
                    "upi://pay?pa=live.demo%40upi&pn=Live%20Demo&am=125.50&"
                    "cu=INR&tn=Synthetic%20test"
                )
            },
        )
        assert parsed.status_code == 200
        assert parsed.json()["payment"]["vpa"] == "live.demo@upi"
        assert parsed.json()["canonical_uri"].startswith("upi://pay?")

        malformed = client.post(
            "/api/v1/payments/parse",
            json={"upi_uri": "upi://pay?pa=live.demo%40upi&tn=bad%ZZvalue"},
        )
        assert malformed.status_code == 422
        assert malformed.json() == {
            "error": {
                "code": "MALFORMED_QUERY",
                "message": "The UPI query has invalid percent encoding",
            }
        }

        scenarios_response = client.get("/api/v1/demo/scenarios")
        assert scenarios_response.status_code == 200
        scenarios = scenarios_response.json()["scenarios"]
        assert [scenario["id"] for scenario in scenarios] == [
            "coffee-shop",
            "tea-stall",
            "marketplace-seller",
            "fake-kyc",
        ]
        # The frozen demo metadata is synchronized by the human after backend
        # and Flutter score changes land together.
        expected_results = {
            "coffee-shop": (0, "SAFE"),
            "tea-stall": (23, "SAFE"),
            "marketplace-seller": (27, "SAFE"),
            "fake-kyc": (100, "HIGH"),
        }
        observed_levels: list[str] = []
        for scenario in scenarios:
            payment_response = client.post(
                "/api/v1/payments/parse", json={"upi_uri": scenario["upi_uri"]}
            )
            assert payment_response.status_code == 200
            score_response = client.post(
                "/api/v1/risk/score",
                json={
                    "payment": payment_response.json()["payment"],
                    "device_id": scenario["device_id"],
                    "context": scenario["context"],
                    "context_token": scenario["context_token"],
                },
            )
            assert score_response.status_code == 200
            score = score_response.json()
            expected_score, expected_level = expected_results[scenario["id"]]
            assert score["score"] == expected_score
            assert score["level"] == expected_level
            observed_levels.append(score["level"])

        assert observed_levels == ["SAFE", "SAFE", "SAFE", "HIGH"]

        local_analysis = client.post(
            "/api/v1/context/analyze",
            json={
                "text": "Urgent KYC payment required now",
                "consent_to_external_ai": False,
            },
        )
        assert local_analysis.status_code == 200
        analyzed = local_analysis.json()
        assert analyzed["source"] == "local_rules"
        assert analyzed["context_token"]

        coffee = scenarios[0]
        coffee_payment = client.post(
            "/api/v1/payments/parse", json={"upi_uri": coffee["upi_uri"]}
        ).json()["payment"]
        context_score = client.post(
            "/api/v1/risk/score",
            json={
                "payment": coffee_payment,
                "device_id": coffee["device_id"],
                "context": analyzed["context"],
                "context_token": analyzed["context_token"],
            },
        )
        assert context_score.status_code == 200
        assert context_score.json()["score"] == 18
