from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any, cast

from sqlalchemy import case, delete, func, or_, select, update
from sqlalchemy.engine import CursorResult
from sqlalchemy.orm import Session

from app.db.models import RefreshSession, User


class UserRepository:
    def __init__(self, session: Session) -> None:
        self._session = session

    def get(self, user_id: str) -> User | None:
        return self._session.get(User, user_id)

    def get_by_email(self, email: str) -> User | None:
        return self._session.scalar(select(User).where(User.email == email.strip().lower()))

    def get_by_google_subject(self, subject: str) -> User | None:
        return self._session.scalar(select(User).where(User.google_subject == subject))

    def create_password_user(self, *, email: str, display_name: str, password_hash: str) -> User:
        user = User(
            email=email.strip().lower(),
            display_name=display_name.strip(),
            password_hash=password_hash,
        )
        self._session.add(user)
        self._session.flush()
        return user

    def create_google_user(self, *, email: str, display_name: str, subject: str) -> User:
        user = User(
            email=email.strip().lower(),
            display_name=display_name.strip(),
            google_subject=subject,
        )
        self._session.add(user)
        self._session.flush()
        return user

    def has_registration_capacity(self, *, max_registered_users: int) -> bool:
        """Check the account ceiling inside the caller's admission lock."""
        if max_registered_users < 1:
            raise ValueError("max_registered_users must be positive")
        registered_users = self._session.scalar(select(func.count()).select_from(User)) or 0
        return registered_users < max_registered_users

    def create_refresh_session(
        self,
        *,
        user: User,
        token_hash: str,
        expires_at: datetime,
        created_at: datetime | None = None,
    ) -> RefreshSession:
        refresh_session = RefreshSession(
            user=user,
            token_hash=token_hash,
            expires_at=expires_at,
            created_at=created_at or datetime.now(UTC),
        )
        self._session.add(refresh_session)
        self._session.flush()
        return refresh_session

    def enforce_active_refresh_session_cap(
        self,
        *,
        user: User,
        protected_session_id: str,
        max_active: int,
        now: datetime | None = None,
    ) -> int:
        """Delete oldest active sessions while always retaining the newly issued one."""
        if max_active < 1:
            raise ValueError("max_active must be positive")
        instant = now or datetime.now(UTC)
        retained_session_ids = (
            select(RefreshSession.id)
            .where(
                RefreshSession.user_id == user.id,
                RefreshSession.revoked_at.is_(None),
                RefreshSession.expires_at > instant,
            )
            .order_by(
                case((RefreshSession.id == protected_session_id, 0), else_=1),
                RefreshSession.created_at.desc(),
                RefreshSession.id.desc(),
            )
            .limit(max_active)
        )
        result = self._session.execute(
            delete(RefreshSession)
            .where(
                RefreshSession.user_id == user.id,
                RefreshSession.revoked_at.is_(None),
                RefreshSession.expires_at > instant,
                RefreshSession.id.not_in(retained_session_ids),
            )
            .execution_options(synchronize_session=False)
        )
        return cast(CursorResult[Any], result).rowcount or 0

    def get_active_refresh_session(
        self, *, token_hash: str, now: datetime | None = None
    ) -> RefreshSession | None:
        instant = now or datetime.now(UTC)
        return self._session.scalar(
            select(RefreshSession).where(
                RefreshSession.token_hash == token_hash,
                RefreshSession.revoked_at.is_(None),
                RefreshSession.expires_at > instant,
            )
        )

    def consume_active_refresh_session(
        self, *, token_hash: str, now: datetime | None = None
    ) -> User | None:
        """Atomically revoke one usable refresh token and return its user."""
        instant = now or datetime.now(UTC)
        result = self._session.execute(
            update(RefreshSession)
            .where(
                RefreshSession.token_hash == token_hash,
                RefreshSession.revoked_at.is_(None),
                RefreshSession.expires_at > instant,
            )
            .values(revoked_at=instant)
            .execution_options(synchronize_session=False)
        )
        if cast(CursorResult[Any], result).rowcount != 1:
            return None
        user_id = self._session.scalar(
            select(RefreshSession.user_id).where(RefreshSession.token_hash == token_hash)
        )
        if user_id is None:
            return None
        return self._session.get(User, user_id)

    def revoke_refresh_session(
        self, refresh_session: RefreshSession, *, now: datetime | None = None
    ) -> None:
        refresh_session.revoked_at = now or datetime.now(UTC)
        self._session.flush()

    def delete_stale_refresh_sessions(
        self,
        *,
        revoked_retention_days: int = 7,
        limit: int = 100,
        now: datetime | None = None,
    ) -> int:
        """Delete one bounded batch of stale sessions without affecting active sessions."""
        if limit < 1:
            raise ValueError("limit must be positive")
        instant = now or datetime.now(UTC)
        revoked_before = instant - timedelta(days=revoked_retention_days)
        stale_session_ids = (
            select(RefreshSession.id)
            .where(
                or_(
                    RefreshSession.expires_at <= instant,
                    RefreshSession.revoked_at <= revoked_before,
                )
            )
            .order_by(RefreshSession.expires_at, RefreshSession.id)
            .limit(limit)
        )
        result = self._session.execute(
            delete(RefreshSession)
            .where(RefreshSession.id.in_(stale_session_ids))
            .execution_options(synchronize_session=False)
        )
        self._session.commit()
        return cast(CursorResult[Any], result).rowcount or 0

    def delete_user(self, user: User) -> None:
        self._session.delete(user)
        self._session.commit()

    def commit(self) -> None:
        self._session.commit()

    def rollback(self) -> None:
        self._session.rollback()
