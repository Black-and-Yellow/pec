from __future__ import annotations

from fastapi import APIRouter, Request, Response, status

from app import __version__
from app.schemas import HealthResponse

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
def health(request: Request, response: Response) -> HealthResponse:
    database_ok = request.app.state.database.is_healthy()
    if not database_ok:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    settings = request.app.state.settings
    return HealthResponse(
        status="ok" if database_ok else "degraded",
        service="finguard-api",
        version=__version__,
        database="ok" if database_ok else "unavailable",
        optional_ai=(
            "configured" if settings.enable_ai_context and settings.gemini_api_key else "disabled"
        ),
    )
