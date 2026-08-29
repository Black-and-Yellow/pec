from __future__ import annotations

from fastapi import APIRouter, HTTPException

from app.schemas import ParsePaymentRequest, ParsePaymentResponse
from app.services.payment_handoff import build_upi_handoff_uri
from app.services.upi_parser import PaymentParseError, parse_upi_uri

router = APIRouter(prefix="/payments", tags=["payments"])


@router.post("/parse", response_model=ParsePaymentResponse)
def parse_payment(request: ParsePaymentRequest) -> ParsePaymentResponse:
    try:
        parsed = parse_upi_uri(request.upi_uri)
    except PaymentParseError as exc:
        raise HTTPException(
            status_code=422, detail={"code": exc.code, "message": exc.message}
        ) from exc
    return ParsePaymentResponse(
        payment=parsed.payment,
        canonical_uri=build_upi_handoff_uri(parsed.payment),
        qr_provenance=parsed.qr_provenance,
    )
