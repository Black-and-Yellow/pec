"""Milestone 3: catch the belief the victim was given, not the payee.

Refund, reward and KYC scams all share one shape: the victim is told money is
coming to them, then walked through an action that sends money away. The
request itself often looks ordinary, so the engine cannot separate it from a
first payment to a new shop. The mismatch between belief and direction can.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.services.intent_shield import PaymentIntent, assess


@pytest.mark.parametrize(
    "intent",
    [
        PaymentIntent.RECEIVE_MONEY,
        PaymentIntent.REFUND_OR_REWARD,
        PaymentIntent.VERIFY_KYC_OR_ACCOUNT,
    ],
)
def test_expecting_money_in_while_the_request_pays_out_warns(
    intent: PaymentIntent,
) -> None:
    result = assess(intent, request_sends_money=True)
    assert result.mismatched is True
    assert result.headline == "STOP - this request sends money."
    assert result.detail
    assert "never required to receive money" in (result.rule or "")


def test_expecting_to_send_money_is_not_a_mismatch() -> None:
    result = assess(PaymentIntent.SEND_MONEY, request_sends_money=True)
    assert result.mismatched is False
    assert result.headline is None


def test_inspecting_only_is_not_a_mismatch() -> None:
    assert assess(PaymentIntent.INSPECT_ONLY, request_sends_money=True).mismatched is False


def test_no_stated_intent_produces_no_warning() -> None:
    """The step is optional; skipping it must not invent a warning."""
    assert assess(None, request_sends_money=True).mismatched is False


def test_a_request_that_does_not_send_money_never_warns() -> None:
    for intent in PaymentIntent:
        assert assess(intent, request_sends_money=False).mismatched is False


def _score(client: TestClient, intent: str | None) -> dict:
    parsed = client.post(
        "/api/v1/payments/parse",
        json={"upi_uri": "upi://pay?pa=refund.desk%40oksbi&am=1&cu=INR"},
    ).json()
    body = {"payment": parsed["payment"], "device_id": "intent-device"}
    if intent is not None:
        body["intent"] = intent
    return client.post("/api/v1/risk/score", json=body).json()


def test_intent_never_changes_the_score(client: TestClient) -> None:
    """The decisive property: a self-reported belief cannot brand a payee.

    If intent moved the score, anyone could push an address into a worse band
    by lying to a dropdown.
    """
    scores = {
        intent: _score(client, intent)["score"]
        for intent in (
            None,
            "SEND_MONEY",
            "RECEIVE_MONEY",
            "REFUND_OR_REWARD",
            "VERIFY_KYC_OR_ACCOUNT",
            "INSPECT_ONLY",
        )
    }
    assert len(set(scores.values())) == 1, scores


def test_the_api_reports_the_mismatch_separately(client: TestClient) -> None:
    body = _score(client, "REFUND_OR_REWARD")
    shield = body["intent_shield"]
    assert shield["mismatched"] is True
    assert shield["intent"] == "REFUND_OR_REWARD"
    assert "STOP" in shield["headline"]
    # And it is not smuggled into the signal list.
    assert not [s for s in body["signals"] if "INTENT" in s["code"]]


def test_the_api_omits_the_shield_when_no_intent_was_stated(client: TestClient) -> None:
    assert _score(client, None)["intent_shield"] is None


def test_a_matching_intent_reports_no_warning(client: TestClient) -> None:
    shield = _score(client, "SEND_MONEY")["intent_shield"]
    assert shield["mismatched"] is False
    assert shield["headline"] is None
