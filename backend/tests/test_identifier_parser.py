from __future__ import annotations

import pytest

from app.services.identifier_parser import IdentifierKind, classify


@pytest.mark.parametrize(
    "raw",
    [
        "upi://pay?pa=shop@okaxis&am=100",
        "UPI://PAY?pa=shop@okaxis",
        "  upi://pay?pa=shop@okaxis  ",
    ],
)
def test_a_payment_link_is_recognised(raw: str) -> None:
    assert classify(raw).kind is IdentifierKind.UPI_LINK


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("shop@okaxis", "shop@okaxis"),
        ("SHOP@OKAXIS", "shop@okaxis"),
        ("  shop@okaxis  ", "shop@okaxis"),
        ("rahul.sharma_91@ybl", "rahul.sharma_91@ybl"),
    ],
)
def test_a_bare_upi_id_is_recognised_and_normalised(raw: str, expected: str) -> None:
    result = classify(raw)
    assert result.kind is IdentifierKind.UPI_ID
    assert result.value == expected


@pytest.mark.parametrize(
    "raw",
    [
        "9876543210",
        "+919876543210",
        "+91 98765 43210",
        "09876543210",
        "98765-43210",
        "(98765) 43210",
        "9876 543 210",
    ],
)
def test_a_mobile_number_survives_however_it_is_written(raw: str) -> None:
    result = classify(raw)
    assert result.kind is IdentifierKind.MOBILE
    assert result.value == "9876543210"


def test_a_mobile_number_expands_to_payable_addresses() -> None:
    result = classify("9876543210")
    assert all(vpa.startswith("9876543210@") for vpa in result.candidate_vpas)
    assert "9876543210@ybl" in result.candidate_vpas


def test_a_phone_derived_address_reads_as_an_address_not_a_number() -> None:
    # It is already payable, so treating it as a bare number would throw away
    # the handle the payer actually needs checked.
    result = classify("9876543210@ybl")
    assert result.kind is IdentifierKind.UPI_ID


@pytest.mark.parametrize(
    "raw",
    ["1234567890", "5876543210", "98765", "98765432101", "+1 555 0100"],
)
def test_numbers_that_are_not_indian_mobiles_are_refused(raw: str) -> None:
    # Indian mobile numbers open with 6-9; anything else is not one.
    assert classify(raw).kind is IdentifierKind.UNSUPPORTED


def test_invisible_characters_from_a_chat_paste_do_not_break_a_number() -> None:
    # Copying out of a messaging app routinely brings a zero-width space along.
    assert classify("98765\u200b43210").kind is IdentifierKind.MOBILE


def test_invisible_characters_do_not_break_an_address() -> None:
    assert classify("shop\u200b@okaxis").kind is IdentifierKind.UPI_ID


@pytest.mark.parametrize("raw", ["", "   ", "not an id", "hello@@world", "a" * 3000])
def test_unusable_input_explains_itself(raw: str) -> None:
    result = classify(raw)
    assert result.kind is IdentifierKind.UNSUPPORTED
    assert result.reason


def test_a_near_miss_address_is_told_what_a_upi_id_looks_like() -> None:
    result = classify("hello@@world")
    assert result.reason is not None
    assert "name@handle" in result.reason
