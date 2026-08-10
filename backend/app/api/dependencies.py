from __future__ import annotations

from collections.abc import Iterator
from typing import TYPE_CHECKING, Annotated

from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.db.models import User
from app.repositories.user_repository import UserRepository
from app.services.auth_service import AuthenticationError, AuthService

if TYPE_CHECKING:
    from app.config import Settings
    from app.services.context_analyzer import ContextAnalyzer
    from app.services.risk_engine import RiskEngine

bearer_scheme = HTTPBearer(auto_error=False)


def get_session(request: Request) -> Iterator[Session]:
    with request.app.state.database.session() as session:
        yield session


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_risk_engine(request: Request) -> RiskEngine:
    return request.app.state.risk_engine


def get_context_analyzer(request: Request) -> ContextAnalyzer:
    return request.app.state.context_analyzer


def get_auth_service(request: Request) -> AuthService:
    return request.app.state.auth_service


def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
    session: Annotated[Session, Depends(get_session)],
    auth_service: Annotated[AuthService, Depends(get_auth_service)],
) -> User:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=401,
            detail={"code": "AUTH_REQUIRED", "message": "Sign in to access this resource"},
            headers={"WWW-Authenticate": "Bearer"},
        )
    try:
        return auth_service.authenticate_access_token(
            UserRepository(session), credentials.credentials
        )
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=401,
            detail={"code": "INVALID_SESSION", "message": str(exc)},
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
