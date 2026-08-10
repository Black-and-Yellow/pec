from __future__ import annotations

from decimal import Decimal

import pytest

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
