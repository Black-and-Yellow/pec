from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException

from app.api.dependencies import get_context_analyzer, get_context_integrity
from app.schemas import ContextAnalyzeRequest, ContextAnalyzeResponse
from app.services.context_analyzer import ContextAnalyzer, ContextInputError
from app.services.context_integrity import ContextIntegrityService

router = APIRouter(prefix="/context", tags=["context"])


@router.post(
    "/analyze",
    response_model=ContextAnalyzeResponse,
    response_model_exclude_none=True,
)
async def analyze_context(
    request: ContextAnalyzeRequest,
    analyzer: Annotated[ContextAnalyzer, Depends(get_context_analyzer)],
    integrity: Annotated[ContextIntegrityService, Depends(get_context_integrity)],
) -> ContextAnalyzeResponse:
    try:
        result = await analyzer.analyze(request)
        if result.source == "none":
            return result
        return result.model_copy(
            update={
                "context_token": integrity.issue(
                    result.context,
                    provenance=result.source,
                )
            }
        )
    except ContextInputError as exc:
        raise HTTPException(
            status_code=422,
            detail={"code": "INVALID_SCREENSHOT", "message": str(exc)},
        ) from exc
