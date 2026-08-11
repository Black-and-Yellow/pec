from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation
from urllib.parse import parse_qsl, urlsplit

from pydantic import ValidationError

from app.schemas import MAX_PAYMENT_AMOUNT, PaymentDetails

AMOUNT_PATTERN = re.compile(r"^\d{1,8}(?:\.\d{1,2})?$")
SUPPORTED_FIELDS = {"pa", "pn", "am", "tn", "cu", "tr", "tid"}


class PaymentParseError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _single_values(query: str) -> dict[str, str]:
    if re.search(r"%(?![0-9A-Fa-f]{2})", query):
        raise PaymentParseError("MALFORMED_QUERY", "The UPI query has invalid percent encoding")
    try:
        pairs = parse_qsl(
            query,
            keep_blank_values=True,
            max_num_fields=30,
            separator="&",
            errors="strict",
        )
    except ValueError as exc:
        raise PaymentParseError("MALFORMED_QUERY", "The UPI query is malformed") from exc

    values: dict[str, str] = {}
    for raw_key, value in pairs:
        key = raw_key.lower()
        if key not in SUPPORTED_FIELDS:
            continue
        if key in values:
            raise PaymentParseError(
                "DUPLICATE_FIELD", f"The UPI request contains more than one '{key}' field"
            )
        values[key] = value
    return values


def _parse_amount(raw_amount: str | None) -> Decimal | None:
    if raw_amount is None or not raw_amount.strip():
        return None
    raw_amount = raw_amount.strip()
    if not AMOUNT_PATTERN.fullmatch(raw_amount):
        raise PaymentParseError(
            "INVALID_AMOUNT", "Amount must be a positive number with at most two decimal places"
        )
    try:
        amount = Decimal(raw_amount)
    except InvalidOperation as exc:
        raise PaymentParseError("INVALID_AMOUNT", "Amount is not a valid decimal number") from exc
    if amount <= 0:
        raise PaymentParseError("INVALID_AMOUNT", "Amount must be greater than zero")
    if amount > MAX_PAYMENT_AMOUNT:
        raise PaymentParseError(
            "INVALID_AMOUNT", f"Amount must not exceed INR {MAX_PAYMENT_AMOUNT:.2f}"
        )
    return amount


def parse_upi_uri(raw_uri: str) -> PaymentDetails:
    uri = raw_uri.strip()
    if len(uri) > 2_048:
        raise PaymentParseError("URI_TOO_LONG", "UPI URI must be 2,048 characters or fewer")

    try:
        parsed = urlsplit(uri)
    except ValueError as exc:
        raise PaymentParseError(
            "MALFORMED_URI", "The supplied value is not a valid UPI URI"
        ) from exc

    if parsed.scheme.lower() != "upi" or parsed.netloc.lower() != "pay":
        raise PaymentParseError(
            "UNSUPPORTED_URI", "Only standard upi://pay payment requests are accepted"
        )
    if parsed.path not in {"", "/"} or parsed.fragment:
        raise PaymentParseError("MALFORMED_URI", "The UPI payment URI contains an unsupported path")

    values = _single_values(parsed.query)
    if not values.get("pa", "").strip():
        raise PaymentParseError("MISSING_VPA", "The UPI payment request is missing the payee VPA")

    currency = values.get("cu", "INR").strip().upper() or "INR"
    reference = values.get("tr") or values.get("tid")
    try:
        return PaymentDetails(
            vpa=values["pa"],
            payee_name=values.get("pn"),
            amount=_parse_amount(values.get("am")),
            transaction_note=values.get("tn"),
            currency=currency,
            transaction_reference=reference,
        )
    except ValidationError as exc:
        first_error = exc.errors(include_url=False, include_input=False)[0]
        field = ".".join(str(part) for part in first_error["loc"])
        message = str(first_error["msg"])
        raise PaymentParseError("INVALID_PAYMENT_FIELD", f"Invalid {field}: {message}") from exc
