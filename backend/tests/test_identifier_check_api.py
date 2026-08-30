from __future__ import annotations

from fastapi.testclient import TestClient


def check(client: TestClient, value: str) -> dict:
    response = client.post("/api/v1/trust/check", json={"value": value})
    assert response.status_code == 200, response.text
    return response.json()


def test_a_payment_link_is_reduced_to_the_address_it_pays(client: TestClient) -> None:
    body = check(client, "upi://pay?pa=secure-kyc-update%40okaxis&am=2500")
    assert body["kind"] == "UPI_LINK"
    assert body["value"] == "secure-kyc-update@okaxis"
    assert body["addresses"][0]["trust"]["grade"] == "D"


def test_a_bare_upi_id_is_checked_directly(client: TestClient) -> None:
    body = check(client, "coffee.corner@okaxis")
    assert body["kind"] == "UPI_ID"
    assert body["addresses"][0]["trust"]["grade"] == "A_PLUS"
    assert body["addresses"][0]["known_to_network"] is True


def test_an_impersonating_id_is_graded_without_any_history(client: TestClient) -> None:
    body = check(client, "SBI-Refund@OKAXIS")
    assert body["value"] == "sbi-refund@okaxis"
    assert body["addresses"][0]["trust"]["grade"] == "D"


def test_a_mobile_number_reports_the_addresses_the_network_knows(client: TestClient) -> None:
    body = check(client, "+91 91827 36450")
    assert body["kind"] == "MOBILE"
    assert body["value"] == "9182736450"
    assert body["addresses_examined"] > 1
    assert [entry["vpa"] for entry in body["addresses"]] == ["9182736450@ybl"]


def test_an_unknown_number_is_not_reported_as_safe(client: TestClient) -> None:
    body = check(client, "9000000001")
    assert body["kind"] == "MOBILE"
    assert body["addresses"] == []
    # Silence about a number must never read as a clean bill of health.
    assert "not a clean bill of health" in body["summary"]


def test_a_lookup_never_writes_to_the_ledger(client: TestClient) -> None:
    """Checking an address repeatedly must not build it a reputation."""
    before = check(client, "chai.point@okicici")["addresses"][0]["trust"]
    for _ in range(5):
        check(client, "chai.point@okicici")
    after = check(client, "chai.point@okicici")["addresses"][0]["trust"]
    assert after["check_count"] == before["check_count"]
    assert after["score"] == before["score"]


def test_a_mobile_check_does_not_write_either(client: TestClient) -> None:
    # This one expands to eight addresses, so a write here would be eight.
    before = check(client, "9182736450@ybl")["addresses"][0]["trust"]["check_count"]
    check(client, "9182736450")
    after = check(client, "9182736450@ybl")["addresses"][0]["trust"]["check_count"]
    assert after == before


def test_unusable_input_is_refused_with_a_reason(client: TestClient) -> None:
    body = check(client, "not an id")
    assert body["kind"] == "UNSUPPORTED"
    assert body["addresses"] == []
    assert body["reason"]


def test_a_malformed_payment_link_reports_why(client: TestClient) -> None:
    body = check(client, "upi://pay?pa=&am=100")
    assert body["kind"] == "UNSUPPORTED"
    assert body["reason"]


def test_a_mule_shaped_ledger_is_named_on_the_lookup_surface(client: TestClient) -> None:
    """The grade alone cannot warn about a collection account.

    A rented account is structurally innocent and often carries no reports, so
    it grades on tenure and reach and its headline reads "nothing adverse on
    file" - the wrong thing to tell someone about to pay one. The traffic is
    where the pattern lives, so the lookup has to say it out loud.
    """
    body = check(client, "rahul.sharma91@ybl")
    assert body["addresses"][0]["trust"]["grade"] == "B"
    assert "Circulated scam addresses are checked like this" in body["summary"]
    # And it must still refuse to call it fraud.
    assert "not as proof of fraud" in body["summary"]


def test_an_ordinary_payee_gets_no_collection_warning(client: TestClient) -> None:
    body = check(client, "coffee.corner@okaxis")
    assert "Circulated scam addresses" not in body["summary"]
