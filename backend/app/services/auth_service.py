from __future__ import annotations

import hashlib
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Lock
from typing import Any

import jwt
from google.auth import exceptions as google_exceptions
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token as google_id_token
from jwt import InvalidTokenError
from pwdlib import PasswordHash
from sqlalchemy.exc import OperationalError

from app.auth_schemas import AuthTokenResponse, UserPayload
from app.config import Settings
from app.db.models import User
from app.repositories.user_repository import UserRepository

password_hash = PasswordHash.recommended()
MAX_ACTIVE_REFRESH_SESSIONS_PER_USER = 5
STALE_REFRESH_SESSION_CLEANUP_BATCH_SIZE = 100


class AuthenticationError(ValueError):
    pass


class RegistrationError(ValueError):
    pass


class RegistrationCapacityError(RegistrationError):
    pass


class GoogleAuthenticationUnavailable(AuthenticationError):
    pass


@dataclass(frozen=True, slots=True)
class GoogleIdentity:
    subject: str
    email: str
    display_name: str


class AuthService:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._registration_lock = Lock()

    def register(
        self,
        repository: UserRepository,
        *,
        email: str,
        password: str,
        display_name: str,
    ) -> AuthTokenResponse:
        self._maintain_refresh_sessions(repository)
        normalized_email = email.strip().lower()
        with self._registration_lock:
            if repository.get_by_email(normalized_email) is not None:
                raise RegistrationError("An account with this email already exists")
            if not repository.has_registration_capacity(
                max_registered_users=self._settings.max_registered_users
            ):
                raise RegistrationCapacityError(
                    "New account registration is temporarily unavailable"
                )
            # Release the read transaction before the deliberately expensive hash so
            # unrelated risk/auth writes are not held behind a SQLite lock.
            repository.rollback()
            user = repository.create_password_user(
                email=normalized_email,
                display_name=display_name,
                password_hash=password_hash.hash(password),
            )
            response = self._new_session(repository, user)
            repository.commit()
            return response

    def login(self, repository: UserRepository, *, email: str, password: str) -> AuthTokenResponse:
        self._maintain_refresh_sessions(repository)
        user = repository.get_by_email(email.strip().lower())
        if (
            user is None
            or not user.is_active
            or user.password_hash is None
            or not password_hash.verify(password, user.password_hash)
        ):
            raise AuthenticationError("Email or password is incorrect")
        response = self._new_session(repository, user)
        repository.commit()
        return response

    def google_login(self, repository: UserRepository, *, raw_id_token: str) -> AuthTokenResponse:
        self._maintain_refresh_sessions(repository)
        identity = self._verify_google_identity(raw_id_token)
        user = repository.get_by_google_subject(identity.subject)
        if user is None:
            repository.rollback()
            with self._registration_lock:
                user = repository.get_by_google_subject(identity.subject)
                if user is None and repository.get_by_email(identity.email) is not None:
                    raise AuthenticationError("Google identity token is invalid")
                if user is None and not repository.has_registration_capacity(
                    max_registered_users=self._settings.max_registered_users
                ):
                    raise RegistrationCapacityError(
                        "New account registration is temporarily unavailable"
                    )
                if user is None:
                    repository.rollback()
                    user = repository.create_google_user(
                        email=identity.email,
                        display_name=identity.display_name,
                        subject=identity.subject,
                    )
                    response = self._new_session(repository, user)
                    repository.commit()
                    return response
        if not user.is_active:
            raise AuthenticationError("This account is disabled")
        response = self._new_session(repository, user)
        repository.commit()
        return response

    def refresh(self, repository: UserRepository, *, raw_refresh_token: str) -> AuthTokenResponse:
        try:
            self._maintain_refresh_sessions(repository)
            user = repository.consume_active_refresh_session(
                token_hash=self._hash_refresh_token(raw_refresh_token)
            )
            if user is None or not user.is_active:
                raise AuthenticationError("Refresh session is invalid or expired")
            response = self._new_session(repository, user)
            repository.commit()
            return response
        except OperationalError as exc:
            repository.rollback()
            database_error = str(exc.orig).lower()
            if "locked" not in database_error and "busy" not in database_error:
                raise
            raise AuthenticationError("Refresh session is invalid or expired") from exc

    def logout(self, repository: UserRepository, *, raw_refresh_token: str) -> bool:
        self._maintain_refresh_sessions(repository)
        stored = repository.get_active_refresh_session(
            token_hash=self._hash_refresh_token(raw_refresh_token)
        )
        if stored is None:
            return False
        repository.revoke_refresh_session(stored)
        repository.commit()
        return True

    def delete_account(
        self, repository: UserRepository, *, user: User, password: str | None
    ) -> None:
        self._maintain_refresh_sessions(repository)
        if user.password_hash is not None and (
            password is None or not password_hash.verify(password, user.password_hash)
        ):
            raise AuthenticationError("Password is incorrect")
        repository.delete_user(user)

    def authenticate_access_token(self, repository: UserRepository, raw_token: str) -> User:
        try:
            claims = jwt.decode(
                raw_token,
                self._settings.auth_secret_key,
                algorithms=["HS256"],
                audience="finguard-api",
                issuer="finguard",
                options={"require": ["sub", "exp", "iat", "type"]},
            )
        except InvalidTokenError as exc:
            raise AuthenticationError("Access token is invalid or expired") from exc
        if claims.get("type") != "access":
            raise AuthenticationError("Access token is invalid or expired")
        user = repository.get(str(claims["sub"]))
        if user is None or not user.is_active:
            raise AuthenticationError("Access token is invalid or expired")
        return user

    def _new_session(self, repository: UserRepository, user: User) -> AuthTokenResponse:
        now = datetime.now(UTC)
        access_expiry = now + timedelta(minutes=self._settings.access_token_minutes)
        access_token = jwt.encode(
            {
                "sub": user.id,
                "iss": "finguard",
                "aud": "finguard-api",
                "iat": now,
                "exp": access_expiry,
                "jti": secrets.token_hex(16),
                "type": "access",
            },
            self._settings.auth_secret_key,
            algorithm="HS256",
        )
        refresh_token = secrets.token_urlsafe(48)
        refresh_session = repository.create_refresh_session(
            user=user,
            token_hash=self._hash_refresh_token(refresh_token),
            expires_at=now + timedelta(days=self._settings.refresh_token_days),
            created_at=now,
        )
        repository.enforce_active_refresh_session_cap(
            user=user,
            protected_session_id=refresh_session.id,
            max_active=MAX_ACTIVE_REFRESH_SESSIONS_PER_USER,
            now=now,
        )
        return AuthTokenResponse(
            access_token=access_token,
            refresh_token=refresh_token,
            expires_in=self._settings.access_token_minutes * 60,
            user=self.user_payload(user),
        )

    @staticmethod
    def _maintain_refresh_sessions(repository: UserRepository) -> None:
        repository.delete_stale_refresh_sessions(limit=STALE_REFRESH_SESSION_CLEANUP_BATCH_SIZE)

    def _verify_google_identity(self, raw_id_token: str) -> GoogleIdentity:
        allowed_audiences = set(self._settings.google_oauth_client_ids)
        if not allowed_audiences:
            raise GoogleAuthenticationUnavailable("Google sign-in is not configured")
        try:
            claims: dict[str, Any] = google_id_token.verify_oauth2_token(
                raw_id_token, google_requests.Request(), audience=None
            )
        except google_exceptions.TransportError as exc:
            raise GoogleAuthenticationUnavailable(
                "Google sign-in is temporarily unavailable"
            ) from exc
        except ValueError as exc:
            raise AuthenticationError("Google identity token is invalid") from exc
        if claims.get("aud") not in allowed_audiences or claims.get("email_verified") is not True:
            raise AuthenticationError("Google identity token is invalid")
        subject = str(claims.get("sub", "")).strip()
        email = str(claims.get("email", "")).strip().lower()
        name = str(claims.get("name", "")).strip() or email.split("@", 1)[0]
        if not subject or not email:
            raise AuthenticationError("Google identity token is missing required claims")
        return GoogleIdentity(subject=subject, email=email, display_name=name[:100])

    @staticmethod
    def _hash_refresh_token(raw_token: str) -> str:
        return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()

    @staticmethod
    def user_payload(user: User) -> UserPayload:
        provider = "google" if user.google_subject and user.password_hash is None else "password"
        return UserPayload(
            id=user.id,
            email=user.email,
            display_name=user.display_name,
            auth_provider=provider,
            created_at=user.created_at,
        )
