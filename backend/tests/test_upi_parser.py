from __future__ import annotations

from decimal import Decimal
from itertools import product
from urllib.parse import urlencode

import pytest

from app.services.payment_handoff import build_upi_handoff_uri
from app.services.upi_parser import PaymentParseError, parse_upi_uri


def test_valid_upi_uri_parsing() -> None:
    payment = parse_upi_uri(
        "upi://pay?pa=Coffee.Corner%40okaxis&pn=Coffee%20Corner&am=180.50&"
        "tn=Morning%20coffee&cu=INR&tr=ORDER-42"
    )

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


@pytest.mark.parametrize(
    "amount", ["1,000", "1.234", "1e3", "0", "-50", "10000000.01"]
)
def test_invalid_amounts_are_rejected(amount: str) -> None:
    with pytest.raises(PaymentParseError) as error:
        parse_upi_uri(f"upi://pay?pa=test%40upi&am={amount}")
    assert error.value.code == "INVALID_AMOUNT"


def test_amount_is_optional() -> None:
    payment = parse_upi_uri("upi://pay?pa=test%40upi")
    assert payment.amount is None
    assert payment.currency == "INR"


def test_maximum_amount_and_tid_reference_are_parsed() -> None:
    payment = parse_upi_uri(
        "upi://pay?pa=test%40upi&am=10000000.00&cu=inr&tid=TXN-DEMO-1"
    )
    assert payment.amount == Decimal("10000000.00")
    assert payment.currency == "INR"
    assert payment.transaction_reference == "TXN-DEMO-1"


def test_uri_length_boundary_is_inclusive() -> None:
    prefix = "upi://pay?pa=test%40upi&ignored="
    uri = prefix + ("a" * (2_048 - len(prefix)))
    assert len(uri) == 2_048
    assert parse_upi_uri(uri).vpa == "test@upi"

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
def test_malformed_encoding_and_control_characters_are_rejected(
    query: str, code: str
) -> None:
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
    )
    assert conflicting.transaction_reference == "PRIMARY-REFERENCE"

    fallback = parse_upi_uri(
        "upi://pay?pa=test%40upi&tr=&tid=SECONDARY-REFERENCE"
    )
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
        parsed = parse_upi_uri(f"upi://pay?{urlencode(fields)}")
        canonical = build_upi_handoff_uri(parsed)
        reparsed = parse_upi_uri(canonical)

        assert reparsed == parsed
        assert build_upi_handoff_uri(reparsed) == canonical
