from __future__ import annotations

from urllib.parse import urlencode

from app.schemas import PaymentDetails


def build_upi_handoff_uri(payment: PaymentDetails) -> str:
    parameters: list[tuple[str, str]] = [("pa", payment.vpa)]
    if payment.payee_name:
        parameters.append(("pn", payment.payee_name))
    if payment.amount is not None:
        parameters.append(("am", f"{payment.amount:.2f}"))
    if payment.transaction_note:
        parameters.append(("tn", payment.transaction_note))
    parameters.append(("cu", payment.currency))
    if payment.transaction_reference:
        parameters.append(("tr", payment.transaction_reference))
    return f"upi://pay?{urlencode(parameters)}"
