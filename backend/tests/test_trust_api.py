from __future__ import annotations

from fastapi.testclient import TestClient


def score_payment(client: TestClient, *, vpa: str, device_id: str, **environment: object):
    body: dict[str, object] = {
        "payment": {"vpa": vpa, "amount": 250, "currency": "INR"},
        "device_id": device_id,
    }
    if environment:
        body["environment"] = environment
    return client.post("/api/v1/risk/score", json=body)


def test_lookup_reports_a_seeded_established_payee(client: TestClient) -> None:
    response = client.post(
        "/api/v1/trust/lookup", json={"vpa": "coffee.corner@okaxis"}
    )
    assert response.status_code == 200
    trust = response.json()["trust"]
    assert trust["grade"] == "A_PLUS"
    assert trust["thin_file"] is False
    assert trust["score"] >= 85
    assert trust["distinct_device_count"] > 100


def test_lookup_reports_a_stranger_as_new_without_a_number(client: TestClient) -> None:
    response = client.post(
        "/api/v1/trust/lookup", json={"vpa": "brand.new.shop@okhdfcbank"}
    )
    trust = response.json()["trust"]
    assert trust["grade"] == "NEW"
    assert trust["score"] is None
    assert trust["check_count"] == 0


def test_lookup_flags_an_address_borrowing_a_bank_name(client: TestClient) -> None:
    response = client.post("/api/v1/trust/lookup", json={"vpa": "sbi.refund@okaxis"})
    trust = response.json()["trust"]
    assert trust["grade"] == "D"
    assert trust["impersonation"] is True


def test_lookup_rejects_an_address_that_is_not_a_vpa(client: TestClient) -> None:
    assert client.post("/api/v1/trust/lookup", json={"vpa": "not a vpa"}).status_code == 422


def test_a_lookup_does_not_count_as_an_encounter(client: TestClient) -> None:
    """Querying an address must not build its reputation.

    If it did, anyone could inflate a scam address into an established one by
    looking it up in a loop.
    """
    for _ in range(6):
        client.post("/api/v1/trust/lookup", json={"vpa": "quiet.payee@okaxis"})
    trust = client.post(
        "/api/v1/trust/lookup", json={"vpa": "quiet.payee@okaxis"}
    ).json()["trust"]
    assert trust["check_count"] == 0
    assert trust["grade"] == "NEW"


def test_scoring_returns_the_payee_trust_report(client: TestClient) -> None:
    response = score_payment(
        client, vpa="coffee.corner@okaxis", device_id="device-trust-1"
    )
    assert response.status_code == 200
    trust = response.json()["payee_trust"]
    assert trust["vpa"] == "coffee.corner@okaxis"
    assert trust["grade"] == "A_PLUS"
    assert {pillar["code"] for pillar in trust["pillars"]} == {
        "IDENTITY",
        "TENURE",
        "REACH",
        "CONDUCT",
        "VELOCITY",
    }


def test_a_payee_first_check_still_reports_it_as_a_stranger(client: TestClient) -> None:
    """The check being made must not be the evidence that the payee is known."""
    trust = score_payment(
        client, vpa="first.ever@okaxis", device_id="device-trust-2"
    ).json()["payee_trust"]
    assert trust["check_count"] == 0
    assert trust["grade"] == "NEW"


def test_repeat_checks_from_one_device_do_not_inflate_reach(client: TestClient) -> None:
    for _ in range(5):
        score_payment(client, vpa="repeat.payee@okaxis", device_id="device-trust-3")
    trust = client.post(
        "/api/v1/trust/lookup", json={"vpa": "repeat.payee@okaxis"}
    ).json()["trust"]
    assert trust["check_count"] == 5
    assert trust["distinct_device_count"] == 1


def test_distinct_devices_accumulate_reach(client: TestClient) -> None:
    for index in range(4):
        score_payment(client, vpa="shared.payee@okaxis", device_id=f"device-trust-4-{index}")
    trust = client.post(
        "/api/v1/trust/lookup", json={"vpa": "shared.payee@okaxis"}
    ).json()["trust"]
    assert trust["distinct_device_count"] == 4


def test_an_active_call_appears_as_a_scored_signal(client: TestClient) -> None:
    response = score_payment(
        client,
        vpa="coffee.corner@okaxis",
        device_id="device-call-1",
        call_activity="CELLULAR",
    )
    assert response.status_code == 200
    body = response.json()
    codes = {signal["code"] for signal in body["signals"]}
    assert "ACTIVE_CALL_DURING_CHECK" in codes


def test_a_call_with_remote_access_pauses_the_handoff(client: TestClient) -> None:
    response = score_payment(
        client,
        vpa="coffee.corner@okaxis",
        device_id="device-call-2",
        call_activity="VOICE_OVER_IP",
        remote_access_tools=["ANYDESK"],
    )
    body = response.json()
    codes = {signal["code"] for signal in body["signals"]}
    assert {"ACTIVE_CALL_DURING_CHECK", "SCREEN_SHARE_DURING_CALL"} <= codes
    assert body["level"] == "HIGH"
    assert body["handoff_policy"] == "PAUSED"


def test_an_unknown_call_state_is_rejected_rather_than_guessed(client: TestClient) -> None:
    response = score_payment(
        client,
        vpa="coffee.corner@okaxis",
        device_id="device-call-3",
        call_activity="ON_A_ZOOM_CALL",
    )
    assert response.status_code == 422
