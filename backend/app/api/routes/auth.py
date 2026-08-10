from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.api.dependencies import (
    get_auth_service,
    get_current_user,
    get_session,
    get_settings,
)
from app.auth_schemas import (
    AuthCapabilitiesResponse,
    AuthTokenResponse,
    DeleteAccountRequest,
    DeleteAccountResponse,
    GoogleLoginRequest,
    LoginRequest,
    LogoutRequest,
    LogoutResponse,
    RefreshRequest,
    RegisterRequest,
    UserPayload,
)
from app.config import Settings
from app.db.models import User
from app.repositories.user_repository import UserRepository
from app.services.auth_service import (
    AuthenticationError,
    AuthService,
    GoogleAuthenticationUnavailable,
    RegistrationError,
)

router = APIRouter(prefix="/auth", tags=["authentication"])


@router.get("/capabilities", response_model=AuthCapabilitiesResponse)
def capabilities(
    settings: Annotated[Settings, Depends(get_settings)],
) -> AuthCapabilitiesResponse:
    return AuthCapabilitiesResponse(google=bool(settings.google_oauth_client_ids))


@router.post("/register", response_model=AuthTokenResponse, status_code=201)
def register(
    payload: RegisterRequest,
    session: Annotated[Session, Depends(get_session)],
    service: Annotated[AuthService, Depends(get_auth_service)],
) -> AuthTokenResponse:
    try:
        return service.register(
            UserRepository(session),
            email=str(payload.email),
            password=payload.password,
            display_name=payload.display_name,
        )
    except (RegistrationError, IntegrityError) as exc:
        session.rollback()
        raise HTTPException(
            status_code=409,
            detail={"code": "ACCOUNT_EXISTS", "message": "An account with this email exists"},
        ) from exc


@router.post("/login", response_model=AuthTokenResponse)
def login(
    payload: LoginRequest,
    session: Annotated[Session, Depends(get_session)],
    service: Annotated[AuthService, Depends(get_auth_service)],
) -> AuthTokenResponse:
    try:
        return service.login(
            UserRepository(session), email=str(payload.email), password=payload.password
        )
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=401,
            detail={"code": "INVALID_CREDENTIALS", "message": str(exc)},
        ) from exc


@router.post("/google", response_model=AuthTokenResponse)
def google_login(
    payload: GoogleLoginRequest,
    session: Annotated[Session, Depends(get_session)],
    service: Annotated[AuthService, Depends(get_auth_service)],
) -> AuthTokenResponse:
    try:
        return service.google_login(UserRepository(session), raw_id_token=payload.id_token)
    except GoogleAuthenticationUnavailable as exc:
        raise HTTPException(
            status_code=503,
            detail={"code": "GOOGLE_AUTH_UNAVAILABLE", "message": str(exc)},
        ) from exc
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=401,
            detail={"code": "INVALID_GOOGLE_IDENTITY", "message": str(exc)},
        ) from exc


@router.post("/refresh", response_model=AuthTokenResponse)
def refresh(
    payload: RefreshRequest,
    session: Annotated[Session, Depends(get_session)],
    service: Annotated[AuthService, Depends(get_auth_service)],
) -> AuthTokenResponse:
    try:
        return service.refresh(
            UserRepository(session), raw_refresh_token=payload.refresh_token
        )
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=401,
            detail={"code": "INVALID_SESSION", "message": str(exc)},
        ) from exc


@router.post("/logout", response_model=LogoutResponse)
def logout(
    payload: LogoutRequest,
    session: Annotated[Session, Depends(get_session)],
    service: Annotated[AuthService, Depends(get_auth_service)],
) -> LogoutResponse:
    return LogoutResponse(
        revoked=service.logout(
            UserRepository(session), raw_refresh_token=payload.refresh_token
        )
    )


@router.get("/me", response_model=UserPayload)
def me(user: Annotated[User, Depends(get_current_user)]) -> UserPayload:
    return AuthService.user_payload(user)


@router.post("/account/delete", response_model=DeleteAccountResponse)
def delete_account(
    payload: DeleteAccountRequest,
    user: Annotated[User, Depends(get_current_user)],
    session: Annotated[Session, Depends(get_session)],
    service: Annotated[AuthService, Depends(get_auth_service)],
) -> DeleteAccountResponse:
    try:
        service.delete_account(
            UserRepository(session), user=user, password=payload.password
        )
    except AuthenticationError as exc:
        raise HTTPException(
            status_code=401,
            detail={"code": "INVALID_CREDENTIALS", "message": str(exc)},
        ) from exc
    return DeleteAccountResponse()
