from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.middleware.base import RequestResponseEndpoint
from starlette.responses import Response

from app import __version__
from app.api.routes import (
    auth,
    context,
    demo,
    health,
    history,
    payments,
    policy,
    response,
    risk,
    trust,
    voice,
)
from app.config import BACKEND_DIRECTORY, Settings
from app.db.database import Database
from app.db.seed import seed_demo_data
from app.integrations.elevenlabs_client import ElevenLabsClient
from app.integrations.gemini_client import GeminiClient
from app.logging_config import configure_logging
from app.repositories.transaction_repository import TransactionRepository
from app.repositories.user_repository import UserRepository
from app.services.auth_service import AuthService
from app.services.context_analyzer import ContextAnalyzer
from app.services.context_integrity import ContextIntegrityService
from app.services.risk_engine import RiskEngine
from app.services.voice_service import VoiceService

logger = logging.getLogger("finguard")
_ASSESSMENT_CLEANUP_INTERVAL_SECONDS = 60 * 60


async def _periodic_assessment_cleanup(
    database: Database,
    *,
    retention_days: int,
    interval_seconds: float,
) -> None:
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            with database.session() as session:
                TransactionRepository(session).delete_expired_assessments_batch(
                    retention_days=retention_days
                )
        except Exception:
            logger.exception("assessment_retention_cleanup_failed")


def create_app(settings: Settings | None = None) -> FastAPI:
    application_settings = settings or Settings.from_env()
    configure_logging(application_settings.log_level)
    database = Database(application_settings.database_url)

    gemini_client = None
    if application_settings.enable_ai_context and application_settings.gemini_api_key:
        gemini_client = GeminiClient(
            api_key=application_settings.gemini_api_key,
            model=application_settings.gemini_model,
            timeout_seconds=application_settings.gemini_timeout_seconds,
        )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        database.create_schema()
        with database.session() as session:
            seed_demo_data(session)
            TransactionRepository(session).delete_expired_assessments(
                retention_days=application_settings.assessment_retention_days
            )
            UserRepository(session).delete_stale_refresh_sessions()
        cleanup_task = asyncio.create_task(
            _periodic_assessment_cleanup(
                database,
                retention_days=application_settings.assessment_retention_days,
                interval_seconds=_ASSESSMENT_CLEANUP_INTERVAL_SECONDS,
            ),
            name="assessment-retention-cleanup",
        )
        try:
            yield
        finally:
            cleanup_task.cancel()
            with suppress(asyncio.CancelledError):
                await cleanup_task
            database.dispose()

    api = FastAPI(
        title="FinGuard API",
        summary="Detect risk. Trigger response.",
        version=__version__,
        lifespan=lifespan,
    )
    api.state.settings = application_settings
    api.state.database = database
    api.state.risk_engine = RiskEngine()
    api.state.auth_service = AuthService(application_settings)
    api.state.context_integrity = ContextIntegrityService(
        application_settings.auth_secret_key
    )
    api.state.context_analyzer = ContextAnalyzer(
        gemini_client=gemini_client,
        enabled=application_settings.enable_ai_context,
        maximum_screenshot_bytes=application_settings.max_screenshot_bytes,
    )
    # Optional, and off unless a key is configured. The voice layer only ever
    # reads a verdict the engine has already reached, so a deployment without
    # it behaves exactly as it did before the layer existed.
    elevenlabs_client = None
    if application_settings.enable_voice_assist and application_settings.elevenlabs_api_key:
        elevenlabs_client = ElevenLabsClient(
            api_key=application_settings.elevenlabs_api_key,
            model=application_settings.elevenlabs_model,
            timeout_seconds=application_settings.elevenlabs_timeout_seconds,
        )
    api.state.voice_service = VoiceService(
        client=elevenlabs_client,
        cache_directory=BACKEND_DIRECTORY / "data" / "voice-cache",
        enabled=application_settings.enable_voice_assist,
    )

    api.add_middleware(
        CORSMiddleware,
        allow_origins=list(application_settings.allowed_origins),
        allow_credentials=False,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=[
            "Content-Type",
            "Accept",
            "Authorization",
            "X-FinGuard-Device-ID",
        ],
    )

    @api.middleware("http")
    async def request_timing(
        request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        request_id = str(uuid4())
        started = time.perf_counter()
        status_code = 500
        try:
            result = await call_next(request)
            status_code = result.status_code
            result.headers["X-Request-ID"] = request_id
            return result
        finally:
            duration_ms = round((time.perf_counter() - started) * 1_000, 2)
            logger.info(
                "request_complete",
                extra={
                    "request_id": request_id,
                    "method": request.method,
                    "path": request.url.path,
                    "status": status_code,
                    "duration_ms": duration_ms,
                },
            )

    @api.exception_handler(RequestValidationError)
    async def validation_error_handler(
        _: Request, exc: RequestValidationError
    ) -> JSONResponse:
        fields = [
            {
                "location": ".".join(str(part) for part in error["loc"]),
                "message": error["msg"],
                "type": error["type"],
            }
            for error in exc.errors()
        ]
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "VALIDATION_ERROR",
                    "message": "One or more request fields are invalid",
                    "fields": fields,
                }
            },
        )

    @api.exception_handler(StarletteHTTPException)
    async def http_error_handler(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        if isinstance(exc.detail, dict):
            detail = exc.detail
        else:
            detail = {"code": f"HTTP_{exc.status_code}", "message": str(exc.detail)}
        return JSONResponse(
            status_code=exc.status_code,
            content={"error": detail},
            headers=exc.headers,
        )

    @api.exception_handler(Exception)
    async def internal_error_handler(_: Request, exc: Exception) -> JSONResponse:
        logger.error("unhandled_error", exc_info=(type(exc), exc, exc.__traceback__))
        return JSONResponse(
            status_code=500,
            content={
                "error": {
                    "code": "INTERNAL_ERROR",
                    "message": "FinGuard could not complete the request",
                }
            },
        )

    prefix = "/api/v1"
    api.include_router(health.router, prefix=prefix)
    api.include_router(auth.router, prefix=prefix)
    api.include_router(payments.router, prefix=prefix)
    api.include_router(risk.router, prefix=prefix)
    api.include_router(trust.router, prefix=prefix)
    api.include_router(policy.router, prefix=prefix)
    api.include_router(context.router, prefix=prefix)
    api.include_router(response.router, prefix=prefix)
    api.include_router(history.router, prefix=prefix)
    api.include_router(demo.router, prefix=prefix)
    api.include_router(voice.router, prefix=prefix)
    return api


app = create_app()
