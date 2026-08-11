from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, or_, select
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

    def create_password_user(
        self, *, email: str, display_name: str, password_hash: str
    ) -> User:
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

    def link_google_subject(self, user: User, subject: str) -> None:
        user.google_subject = subject
        self._session.flush()

    def create_refresh_session(
        self, *, user: User, token_hash: str, expires_at: datetime
    ) -> RefreshSession:
        refresh_session = RefreshSession(
            user=user,
            token_hash=token_hash,
            expires_at=expires_at,
        )
        self._session.add(refresh_session)
        self._session.flush()
        return refresh_session

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

    def revoke_refresh_session(
        self, refresh_session: RefreshSession, *, now: datetime | None = None
    ) -> None:
        refresh_session.revoked_at = now or datetime.now(UTC)
        self._session.flush()

    def delete_stale_refresh_sessions(
        self, *, revoked_retention_days: int = 7, now: datetime | None = None
    ) -> int:
        """Bound authentication-session storage without affecting active sessions."""
        instant = now or datetime.now(UTC)
        revoked_before = instant - timedelta(days=revoked_retention_days)
        result = self._session.execute(
            delete(RefreshSession).where(
                or_(
                    RefreshSession.expires_at <= instant,
                    RefreshSession.revoked_at <= revoked_before,
                )
            )
        )
        self._session.commit()
        return result.rowcount or 0

    def delete_user(self, user: User) -> None:
        self._session.delete(user)
        self._session.commit()

    def commit(self) -> None:
        self._session.commit()
