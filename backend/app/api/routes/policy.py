from __future__ import annotations

from fastapi import APIRouter

from app.risk_policy import THRESHOLDS, WEIGHTS
from app.schemas import (
    PolicyBandPayload,
    PolicyCardResponse,
    PolicySignalPayload,
)
from app.services.policy_card import (
    CALIBRATION_STATEMENT,
    LIMITATIONS,
    POLICY_VERSION,
    bands,
    weight_entries,
)

router = APIRouter(prefix="/policy", tags=["policy"])


@router.get("/card", response_model=PolicyCardResponse)
def policy_card() -> PolicyCardResponse:
    """Publish the scoring policy so the app never keeps its own copy.

    The weights live in one place and are served from it. A client that
    hard-codes them becomes a second authority that can silently disagree
    with the engine, which is exactly the bug this endpoint prevents.
    """
    return PolicyCardResponse(
        policy_version=POLICY_VERSION,
        bands=[
            PolicyBandPayload(
                name=band.name,  # type: ignore[arg-type]
                minimum=band.minimum,
                maximum=band.maximum,
                meaning=band.meaning,
            )
            for band in bands(THRESHOLDS)
        ],
        signals=[
            PolicySignalPayload(**entry)  # type: ignore[arg-type]
            for entry in weight_entries(WEIGHTS)
        ],
        limitations=list(LIMITATIONS),
        calibration_statement=CALIBRATION_STATEMENT,
    )
