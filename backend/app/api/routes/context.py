from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException

from app.api.dependencies import get_context_analyzer
from app.schemas import ContextAnalyzeRequest, ContextAnalyzeResponse
from app.services.context_analyzer import ContextAnalyzer, ContextInputError

router = APIRouter(prefix="/context", tags=["context"])


@router.post("/analyze", response_model=ContextAnalyzeResponse)
async def analyze_context(
    request: ContextAnalyzeRequest,
    analyzer: Annotated[ContextAnalyzer, Depends(get_context_analyzer)],
) -> ContextAnalyzeResponse:
    try:
        return await analyzer.analyze(request)
    except ContextInputError as exc:
        raise HTTPException(
            status_code=422,
            detail={"code": "INVALID_SCREENSHOT", "message": str(exc)},
        ) from exc
