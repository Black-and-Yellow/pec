from __future__ import annotations

from decimal import Decimal
from itertools import product
from urllib.parse import parse_qs, urlencode, urlsplit

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.schemas import QrProvenance, RiskScoreRequest
from app.services.payment_handoff import build_upi_handoff_uri
from app.services.upi_parser import PaymentParseError, parse_upi_uri


def test_valid_upi_uri_parsing() -> None:
    payment = parse_upi_uri(
        "upi://pay?pa=Coffee.Corner%40okaxis&pn=Coffee%20Corner&am=180.50&"
        "tn=Morning%20coffee&cu=INR&tr=ORDER-42"
    ).payment

    assert payment.vpa == "coffee.corner@okaxis"
    assert payment.payee_name == "Coffee Corner"
    assert payment.amount == Decimal("180.50")
    assert payment.transaction_note == "Morning coffee"
    assert payment.currency == "INR"
    assert payment.transaction_reference == "ORDER-42"


@pytest.mark.parametrize(
    ("uri", "code"),
    [
        ("https://example.com/pay?pa=a@upi", "UNSUPPORTED_URI"),
        ("upi://collect?pa=a@upi", "UNSUPPORTED_URI"),
        ("upi://pay/redirect?pa=a@upi", "MALFORMED_URI"),
        ("upi://pay?pa=a@upi#https://evil.example", "MALFORMED_URI"),
        ("upi://pay?pa=not-a-vpa", "INVALID_PAYMENT_FIELD"),
        ("upi://pay?pa=a@upi&pa=b@upi", "DUPLICATE_FIELD"),
        ("upi://pay?PA=a@upi&pa=b@upi", "DUPLICATE_FIELD"),
        ("upi://pay?pa=test%40upi&tn=bad%ZZvalue", "MALFORMED_QUERY"),
    ],
)
def test_malformed_upi_uri_handling(uri: str, code: str) -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(uri)
    assert error.value.code == code


def test_missing_vpa() -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri("upi://pay?pn=Missing%20recipient&am=50")
    assert error.value.code == "MISSING_VPA"


@pytest.mark.parametrize("amount", ["1,000", "1.234", "1e3", "0", "-50", "10000000.01"])
def test_invalid_amounts_are_rejected(amount: str) -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"upi://pay?pa=test%40upi&am={amount}")
    assert error.value.code == "INVALID_AMOUNT"


def test_amount_is_optional() -> None:
    payment = parse_upi_uri("upi://pay?pa=test%40upi").payment
    assert payment.amount is None
    assert payment.currency == "INR"


def test_maximum_amount_and_tid_reference_are_parsed() -> None:
    payment = parse_upi_uri("upi://pay?pa=test%40upi&am=10000000.00&cu=inr&tid=TXN-DEMO-1").payment
    assert payment.amount == Decimal("10000000.00")
    assert payment.currency == "INR"
    assert payment.transaction_reference == "TXN-DEMO-1"


def test_uri_length_boundary_is_inclusive() -> None:
    prefix = "upi://pay?pa=test%40upi&ignored="
    uri = prefix + ("a" * (2_048 - len(prefix)))
    assert len(uri) == 2_048
    assert parse_upi_uri(uri).payment.vpa == "test@upi"

    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"{uri}a")
    assert error.value.code == "URI_TOO_LONG"


def test_query_field_count_is_bounded() -> None:
    fields = ["pa=test%40upi", *(f"ignored{index}=x" for index in range(30))]
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"upi://pay?{'&'.join(fields)}")
    assert error.value.code == "MALFORMED_QUERY"


@pytest.mark.parametrize(
    ("query", "code"),
    [
        ("tn=incomplete%", "MALFORMED_QUERY"),
        ("tn=invalid%FFutf8", "MALFORMED_QUERY"),
        ("tn=invalid%C3%28utf8", "MALFORMED_QUERY"),
        ("tn=line%0Abreak", "INVALID_PAYMENT_FIELD"),
        ("pn=demo%7Fmerchant", "INVALID_PAYMENT_FIELD"),
    ],
)
def test_malformed_encoding_and_control_characters_are_rejected(query: str, code: str) -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"upi://pay?pa=test%40upi&{query}")
    assert error.value.code == code


@pytest.mark.parametrize(
    "duplicate",
    [
        "PA=other%40upi",
        "pn=First&PN=Second",
        "am=1&AM=2",
        "tn=First&TN=Second",
        "cu=INR&CU=INR",
        "tr=FIRST&tr=SECOND",
        "tid=FIRST&TID=SECOND",
        "sign=FIRST&SIGN=SECOND",
        "orgid=FIRST&ORGID=SECOND",
        "mode=01&MODE=02",
        "mc=5411&MC=5812",
    ],
)
def test_every_supported_field_has_case_insensitive_duplicate_rejection(
    duplicate: str,
) -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"upi://pay?pa=test%40upi&{duplicate}")
    assert error.value.code == "DUPLICATE_FIELD"


def test_tr_precedes_tid_and_blank_tr_falls_back_to_tid() -> None:
    conflicting = parse_upi_uri(
        "upi://pay?pa=test%40upi&tr=PRIMARY-REFERENCE&tid=SECONDARY-REFERENCE"
    ).payment
    assert conflicting.transaction_reference == "PRIMARY-REFERENCE"

    fallback = parse_upi_uri("upi://pay?pa=test%40upi&tr=&tid=SECONDARY-REFERENCE").payment
    assert fallback.transaction_reference == "SECONDARY-REFERENCE"


def test_parse_canonicalize_parse_equivalence_over_generated_matrix() -> None:
    field_matrix = product(
        ("alpha@upi", "merchant.store@okaxis"),
        (None, "Demo Merchant"),
        (None, "1", "180.50"),
        (None, "Invoice & delivery"),
        (None, "ORDER-42"),
    )
    for vpa, name, amount, note, reference in field_matrix:
        fields = [("pa", vpa), ("cu", "inr")]
        fields.extend(
            (key, value)
            for key, value in (
                ("pn", name),
                ("am", amount),
                ("tn", note),
                ("tid", reference),
            )
            if value is not None
        )
        parsed = parse_upi_uri(f"upi://pay?{urlencode(fields)}").payment
        canonical = build_upi_handoff_uri(parsed)
        reparsed = parse_upi_uri(canonical).payment

        assert reparsed == parsed
        assert build_upi_handoff_uri(reparsed) == canonical


def test_qr_provenance_is_presence_only_and_excluded_from_canonical_uri() -> None:
    parsed = parse_upi_uri(
        "upi://pay?pa=merchant%40okaxis&pn=Merchant&am=250&tr=ORDER-9&"
        "sign=opaque-sign%2Bvalue%3D&orgid=org-123&mode=02&mc=5411"
    )

    assert parsed.qr_provenance.model_dump() == {
        "sign_present": True,
        "orgid_present": True,
        "mode_present": True,
        "merchant_category_present": True,
    }
    canonical = build_upi_handoff_uri(parsed.payment)
    assert set(parse_qs(urlsplit(canonical).query)) == {"pa", "pn", "am", "cu", "tr"}


@pytest.mark.parametrize(
    "field",
    [
        "sign=",
        "sign=bad%0Avalue",
        f"sign={'x' * 1_025}",
        "orgid=bad%20value",
        "mode=merchant",
        "mode=123",
        "mc=12",
        "mc=retail",
    ],
)
def test_malformed_qr_provenance_fields_are_rejected(field: str) -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"upi://pay?pa=merchant%40okaxis&{field}")

    assert error.value.code == "INVALID_PROVENANCE_FIELD"
    assert "opaque-sign" not in error.value.message


def test_qr_provenance_schema_is_strict_and_optional_on_risk_requests() -> None:
    provenance = QrProvenance(
        sign_present=True,
        orgid_present=False,
        mode_present=True,
        merchant_category_present=True,
    )
    request = RiskScoreRequest(
        payment={"vpa": "merchant@okaxis", "amount": 250, "transaction_reference": "ORDER-9"},
        device_id="qr-test-device",
        qr_provenance=provenance,
    )
    without_provenance = RiskScoreRequest(
        payment={"vpa": "person@upi"},
        device_id="qr-test-device",
    )

    assert request.qr_provenance == provenance
    assert without_provenance.qr_provenance is None

    with pytest.raises(ValidationError):
        QrProvenance.model_validate(
            {
                "sign_present": "true",
                "orgid_present": False,
                "mode_present": False,
                "merchant_category_present": False,
            }
        )
    with pytest.raises(ValidationError):
        QrProvenance.model_validate(
            {
                "sign_present": True,
                "orgid_present": False,
                "mode_present": False,
                "merchant_category_present": False,
                "sign": "opaque-sign-value",
            }
        )


def test_parse_api_returns_only_qr_provenance_presence(client: TestClient) -> None:
    response = client.post(
        "/api/v1/payments/parse",
        json={
            "upi_uri": (
                "upi://pay?pa=merchant%40okaxis&am=250&tr=ORDER-9&"
                "sign=opaque-sign-value&orgid=org-123&mode=02&mc=5411"
            )
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["qr_provenance"] == {
        "sign_present": True,
        "orgid_present": True,
        "mode_present": True,
        "merchant_category_present": True,
    }
    assert "opaque-sign-value" not in response.text
    assert "org-123" not in response.text
    assert set(parse_qs(urlsplit(body["canonical_uri"]).query)) == {
        "pa",
        "am",
        "cu",
        "tr",
    }
