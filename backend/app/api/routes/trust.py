from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.dependencies import get_session
from app.repositories.indicator_repository import IndicatorRepository
from app.repositories.reputation_repository import ReputationRepository
from app.schemas import (
    CheckedAddress,
    IdentifierCheckRequest,
    IdentifierCheckResponse,
    PayeeTrust,
    TrustLookupRequest,
    TrustLookupResponse,
)
from app.services import mule_signature
from app.services.identifier_parser import IdentifierKind, classify
from app.services.trust_score import TrustInputs, TrustScorer
from app.services.upi_parser import PaymentParseError, parse_upi_uri

router = APIRouter(prefix="/trust", tags=["trust"])


@router.post("/lookup", response_model=TrustLookupResponse)
def lookup_payee_trust(
    request: TrustLookupRequest,
    session: Annotated[Session, Depends(get_session)],
) -> TrustLookupResponse:
    """Report a payee's standing without scoring or storing a payment.

    A lookup is a read. It deliberately does not touch the reputation ledger:
    if simply asking about an address counted as an encounter with it, the
    ledger would measure curiosity rather than use, and anyone could inflate a
    scam address into a well-established one by querying it in a loop.
    """
    indicator = IndicatorRepository(session).find_vpa(request.vpa)
    trust = TrustScorer().score(
        TrustInputs(
            vpa=request.vpa,
            reputation=ReputationRepository(session).snapshot(request.vpa),
            seeded_indicator_label=indicator.label if indicator is not None else None,
        )
    )
    return TrustLookupResponse(trust=trust)


@router.post("/check", response_model=IdentifierCheckResponse)
def check_identifier(
    request: IdentifierCheckRequest,
    session: Annotated[Session, Depends(get_session)],
) -> IdentifierCheckResponse:
    """Check whatever the user pasted: a payment link, a UPI ID, or a number.

    Like ``/lookup`` this is a read and never writes to the ledger.

    A phone number is not itself payable, so it is expanded into the addresses
    it could be payable at and each is consulted. Only addresses the network
    actually knows are reported: listing eight NEW grades for eight handles
    nobody has ever used would be noise dressed as an answer.
    """
    identifier = classify(request.value)
    indicators = IndicatorRepository(session)
    reputation = ReputationRepository(session)
    scorer = TrustScorer()

    def score(vpa: str) -> PayeeTrust:
        indicator = indicators.find_vpa(vpa)
        return scorer.score(
            TrustInputs(
                vpa=vpa,
                reputation=reputation.snapshot(vpa),
                seeded_indicator_label=indicator.label if indicator is not None else None,
            )
        )

    def with_collection_warning(vpa: str, headline: str) -> str:
        """Lead with the mule shape when the ledger has it.

        The grade cannot carry this on its own. A rented collection account is
        structurally innocent and often has no reports yet, so it grades on
        tenure and reach like any other address and the headline reads
        "nothing adverse on file" - which is exactly the wrong thing to tell
        someone about to pay one. The pattern lives in the traffic, so it has
        to be said out loud here, not only when a payment is being scored.
        """
        shape = mule_signature.assess(reputation.snapshot(vpa))
        if not shape.matched:
            return headline + "."
        return (
            f"{shape.evidence} The grade itself reads on tenure and reach: "
            f"{headline.lower()}."
        )

    if identifier.kind is IdentifierKind.UNSUPPORTED:
        return IdentifierCheckResponse(
            kind="UNSUPPORTED",
            value=identifier.value,
            summary="This could not be read as something FinGuard can check.",
            reason=identifier.reason,
        )

    if identifier.kind is IdentifierKind.UPI_LINK:
        try:
            parsed = parse_upi_uri(identifier.value)
        except PaymentParseError as exc:
            return IdentifierCheckResponse(
                kind="UNSUPPORTED",
                value=identifier.value[:64],
                summary="This payment link could not be read.",
                reason=exc.message,
            )
        vpa = parsed.payment.vpa
        trust = score(vpa)
        return IdentifierCheckResponse(
            kind="UPI_LINK",
            value=vpa,
            addresses=[
                CheckedAddress(
                    vpa=vpa,
                    trust=trust,
                    known_to_network=not trust.thin_file,
                )
            ],
            addresses_examined=1,
            summary=f"This link pays {vpa}. {with_collection_warning(vpa, trust.headline)}",
        )

    if identifier.kind is IdentifierKind.UPI_ID:
        trust = score(identifier.value)
        return IdentifierCheckResponse(
            kind="UPI_ID",
            value=identifier.value,
            addresses=[
                CheckedAddress(
                    vpa=identifier.value,
                    trust=trust,
                    known_to_network=not trust.thin_file,
                )
            ],
            addresses_examined=1,
            summary=with_collection_warning(identifier.value, trust.headline),
        )

    # A mobile number: report only the addresses the network has actually seen.
    known: list[CheckedAddress] = []
    for candidate in identifier.candidate_vpas:
        trust = score(candidate)
        if not trust.thin_file or trust.impersonation:
            known.append(
                CheckedAddress(vpa=candidate, trust=trust, known_to_network=not trust.thin_file)
            )
    examined = len(identifier.candidate_vpas)
    if known:
        # A withheld score means a thin file, which is not evidence of harm, so
        # it sorts as neutral rather than as the worst thing found.
        def standing(entry: CheckedAddress) -> int:
            return entry.trust.score if entry.trust.score is not None else 100

        worst = min(known, key=standing)
        summary = (
            f"{len(known)} of {examined} phone-shaped UPI addresses built from these "
            f"digits have been seen in FinGuard checks before. This does not identify "
            f"who owns the number or which bank account it belongs to. The weakest is "
            f"{worst.vpa}: {with_collection_warning(worst.vpa, worst.trust.headline)}"
        )
    else:
        summary = (
            f"None of the {examined} phone-shaped UPI addresses built from these digits "
            "has been seen in a FinGuard check. FinGuard cannot look up who owns a "
            "number or which account it is linked to; it only recognises addresses it "
            "has already seen. Silence here is not a clean bill of health."
        )
    return IdentifierCheckResponse(
        kind="MOBILE",
        value=identifier.value,
        addresses=known,
        addresses_examined=examined,
        summary=summary,
    )
