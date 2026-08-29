from __future__ import annotations

import sqlite3
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from fastapi.testclient import TestClient
from google.auth import exceptions as google_exceptions
from sqlalchemy import func, select
from sqlalchemy.exc import OperationalError

from app.config import Settings
from app.db.database import Database
from app.db.models import RefreshSession, User
from app.main import create_app
from app.repositories.user_repository import UserRepository
from app.services import auth_service as auth_service_module
from app.services.auth_service import (
    AuthenticationError,
    AuthService,
    GoogleIdentity,
    RegistrationCapacityError,
)


def _register(client: TestClient) -> dict[str, object]:
    response = client.post(
        "/api/v1/auth/register",
        json={
            "email": "person@example.com",
            "password": "correct-horse-42",
            "display_name": "Test Person",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_register_login_and_authenticated_profile(client: TestClient) -> None:
    capabilities = client.get("/api/v1/auth/capabilities")
    assert capabilities.status_code == 200
    assert capabilities.json() == {"email_password": True, "google": False}

    registered = _register(client)
    assert registered["token_type"] == "bearer"
    assert registered["expires_in"] == 900
    assert registered["user"]["email"] == "person@example.com"
    assert registered["user"]["auth_provider"] == "password"
    assert len(registered["access_token"]) > 100
    assert len(registered["refresh_token"]) > 40

    profile = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {registered['access_token']}"},
    )
    assert profile.status_code == 200
    assert profile.json()["display_name"] == "Test Person"

    logged_in = client.post(
        "/api/v1/auth/login",
        json={"email": "PERSON@example.com", "password": "correct-horse-42"},
    )
    assert logged_in.status_code == 200
    assert logged_in.json()["user"]["id"] == registered["user"]["id"]


def test_duplicate_registration_and_bad_credentials_fail_safely(client: TestClient) -> None:
    _register(client)
    duplicate = client.post(
        "/api/v1/auth/register",
        json={
            "email": "PERSON@example.com",
            "password": "another-password-7",
            "display_name": "Other Person",
        },
    )
    assert duplicate.status_code == 409
    assert duplicate.json()["error"]["code"] == "ACCOUNT_EXISTS"

    bad_login = client.post(
        "/api/v1/auth/login",
        json={"email": "person@example.com", "password": "wrong-password"},
    )
    assert bad_login.status_code == 401
    assert bad_login.json()["error"]["code"] == "INVALID_CREDENTIALS"
    assert "correct-horse-42" not in bad_login.text


def test_refresh_rotation_and_logout_revoke_sessions(client: TestClient) -> None:
    registered = _register(client)
    original_refresh = registered["refresh_token"]

    refreshed = client.post("/api/v1/auth/refresh", json={"refresh_token": original_refresh})
    assert refreshed.status_code == 200
    replacement = refreshed.json()["refresh_token"]
    assert replacement != original_refresh

    replay = client.post("/api/v1/auth/refresh", json={"refresh_token": original_refresh})
    assert replay.status_code == 401

    logout = client.post("/api/v1/auth/logout", json={"refresh_token": replacement})
    assert logout.status_code == 200
    assert logout.json() == {"revoked": True}
    assert (
        client.post("/api/v1/auth/refresh", json={"refresh_token": replacement}).status_code == 401
    )


def test_new_sessions_invalidate_the_oldest_token_at_the_per_user_cap(
    client: TestClient,
) -> None:
    registered = _register(client)
    issued_refresh_tokens = [registered["refresh_token"]]
    for index in range(auth_service_module.MAX_ACTIVE_REFRESH_SESSIONS_PER_USER + 2):
        logged_in = client.post(
            "/api/v1/auth/login",
            json={
                "email": "person@example.com",
                "password": "correct-horse-42",
            },
        )
        assert logged_in.status_code == 200, f"login {index}: {logged_in.text}"
        issued_refresh_tokens.append(logged_in.json()["refresh_token"])

    now = datetime.now(UTC)
    with client.app.state.database.session() as session:
        user = UserRepository(session).get_by_email("person@example.com")
        assert user is not None
        active_count = session.scalar(
            select(func.count())
            .select_from(RefreshSession)
            .where(
                RefreshSession.user_id == user.id,
                RefreshSession.revoked_at.is_(None),
                RefreshSession.expires_at > now,
            )
        )

    assert active_count == auth_service_module.MAX_ACTIVE_REFRESH_SESSIONS_PER_USER
    oldest = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": issued_refresh_tokens[0]},
    )
    newest = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": issued_refresh_tokens[-1]},
    )
    assert oldest.status_code == 401
    assert newest.status_code == 200


def test_failed_login_runs_only_one_bounded_stale_session_cleanup_batch(
    client: TestClient,
) -> None:
    registered = _register(client)
    now = datetime.now(UTC)
    stale_count = auth_service_module.STALE_REFRESH_SESSION_CLEANUP_BATCH_SIZE + 1
    with client.app.state.database.session() as session:
        user = session.get(User, registered["user"]["id"])
        assert user is not None
        session.add_all(
            [
                RefreshSession(
                    id=f"expired-{index}",
                    user=user,
                    token_hash=f"{index + 1:064x}",
                    expires_at=now - timedelta(minutes=1),
                    created_at=now - timedelta(days=1),
                )
                for index in range(stale_count)
            ]
        )
        session.commit()

    failed_login = client.post(
        "/api/v1/auth/login",
        json={"email": "person@example.com", "password": "wrong-password"},
    )
    assert failed_login.status_code == 401

    with client.app.state.database.session() as session:
        remaining_stale = session.scalar(
            select(func.count()).select_from(RefreshSession).where(RefreshSession.expires_at <= now)
        )
    assert remaining_stale == 1


def test_concurrent_refresh_requests_mint_only_one_successor(live_api_url: str) -> None:
    with httpx.Client(base_url=live_api_url, timeout=10, trust_env=False) as client:
        registered = client.post(
            "/api/v1/auth/register",
            json={
                "email": "refresh-race@example.com",
                "password": "concurrent-refresh-42",
                "display_name": "Refresh Race",
            },
        )
    assert registered.status_code == 201
    original_refresh = registered.json()["refresh_token"]
    start = threading.Barrier(3)

    def refresh_once() -> int:
        start.wait(timeout=5)
        with httpx.Client(base_url=live_api_url, timeout=10, trust_env=False) as client:
            return client.post(
                "/api/v1/auth/refresh", json={"refresh_token": original_refresh}
            ).status_code

    with ThreadPoolExecutor(max_workers=2) as executor:
        requests = [executor.submit(refresh_once) for _ in range(2)]
        start.wait(timeout=5)
        statuses = sorted(request.result(timeout=15) for request in requests)

    assert statuses == [200, 401]


def test_refresh_lock_contention_fails_closed_as_an_invalid_session(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    def raise_locked(_: UserRepository, *, token_hash: str, now: object = None) -> None:
        del token_hash, now
        raise OperationalError(
            "synthetic update",
            {},
            sqlite3.OperationalError("database is locked"),
        )

    monkeypatch.setattr(UserRepository, "consume_active_refresh_session", raise_locked)
    response = client.post("/api/v1/auth/refresh", json={"refresh_token": "x" * 48})

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "INVALID_SESSION"


def test_registration_capacity_is_checked_before_password_hashing(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{(tmp_path / 'registration-cap.db').as_posix()}",
        allowed_origins=(),
        max_registered_users=1,
    )
    with TestClient(create_app(settings)) as capped_client:
        first = capped_client.post(
            "/api/v1/auth/register",
            json={
                "email": "first@example.com",
                "password": "first-password-42",
                "display_name": "First User",
            },
        )
        assert first.status_code == 201

        class HashMustNotRun:
            @staticmethod
            def hash(_: str) -> str:
                raise AssertionError("password hashing ran after the user cap was reached")

        monkeypatch.setattr(auth_service_module, "password_hash", HashMustNotRun())
        rejected = capped_client.post(
            "/api/v1/auth/register",
            json={
                "email": "second@example.com",
                "password": "second-password-42",
                "display_name": "Second User",
            },
        )

    assert rejected.status_code == 503
    assert rejected.json()["error"] == {
        "code": "REGISTRATION_UNAVAILABLE",
        "message": "New account registration is temporarily unavailable",
    }


def test_concurrent_registration_cannot_exceed_the_total_user_cap(tmp_path) -> None:
    database = Database(f"sqlite:///{(tmp_path / 'registration-race.db').as_posix()}")
    database.create_schema()
    service = AuthService(Settings(app_env="test", max_registered_users=1))
    start = threading.Barrier(3)

    def register_once(index: int) -> str:
        start.wait(timeout=5)
        with database.session() as session:
            try:
                service.register(
                    UserRepository(session),
                    email=f"racer-{index}@example.com",
                    password=f"racing-password-{index}",
                    display_name=f"Racer {index}",
                )
            except RegistrationCapacityError:
                return "capacity"
        return "created"

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            registrations = [executor.submit(register_once, index) for index in range(2)]
            start.wait(timeout=5)
            outcomes = sorted(result.result(timeout=15) for result in registrations)

        with database.session() as session:
            user_count = session.scalar(select(func.count()).select_from(User))
        assert outcomes == ["capacity", "created"]
        assert user_count == 1
    finally:
        database.dispose()


def test_registration_hash_does_not_hold_a_sqlite_lock(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = Database(f"sqlite:///{(tmp_path / 'registration-lock.db').as_posix()}")
    database.create_schema()
    with database.session() as session:
        session.add(User(email="existing@example.com", display_name="Existing User"))
        session.commit()

    hash_started = threading.Event()
    release_hash = threading.Event()

    class BlockingPasswordHash:
        @staticmethod
        def hash(_: str) -> str:
            hash_started.set()
            if not release_hash.wait(timeout=5):
                raise AssertionError("test did not release the password hash")
            return "synthetic-password-hash"

    monkeypatch.setattr(auth_service_module, "password_hash", BlockingPasswordHash())
    service = AuthService(Settings(app_env="test", max_registered_users=2))

    def register() -> None:
        with database.session() as session:
            service.register(
                UserRepository(session),
                email="new@example.com",
                password="new-password-42",
                display_name="New User",
            )

    def update_existing_user() -> None:
        with database.session() as session:
            existing = UserRepository(session).get_by_email("existing@example.com")
            assert existing is not None
            existing.display_name = "Updated While Hashing"
            session.commit()

    try:
        with ThreadPoolExecutor(max_workers=2) as executor:
            registration = executor.submit(register)
            assert hash_started.wait(timeout=5)
            concurrent_write = executor.submit(update_existing_user)
            try:
                concurrent_write.result(timeout=1)
            finally:
                release_hash.set()
            registration.result(timeout=5)
    finally:
        release_hash.set()
        database.dispose()


def test_google_account_creation_is_subject_bound_and_obeys_capacity(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    database = Database(f"sqlite:///{(tmp_path / 'google-cap.db').as_posix()}")
    database.create_schema()
    service = AuthService(Settings(app_env="test", max_registered_users=2))

    def identity_for_token(_: AuthService, raw_token: str) -> GoogleIdentity:
        if raw_token == "password-email-collision":
            return GoogleIdentity(
                subject="unknown-password-collision",
                email="person@example.com",
                display_name="Password Collision",
            )
        if raw_token == "google-owner":
            return GoogleIdentity(
                subject="google-owner-subject",
                email="google-owner@example.com",
                display_name="Google Owner",
            )
        if raw_token == "google-email-collision":
            return GoogleIdentity(
                subject="different-google-subject",
                email="google-owner@example.com",
                display_name="Google Collision",
            )
        return GoogleIdentity(
            subject="capacity-subject",
            email="capacity@example.com",
            display_name="Capacity User",
        )

    monkeypatch.setattr(AuthService, "_verify_google_identity", identity_for_token)
    try:
        with database.session() as session:
            service.register(
                UserRepository(session),
                email="person@example.com",
                password="correct-horse-42",
                display_name="Test Person",
            )

        with (
            database.session() as session,
            pytest.raises(AuthenticationError, match="Google identity token is invalid"),
        ):
            service.google_login(UserRepository(session), raw_id_token="password-email-collision")

        with database.session() as session:
            created = service.google_login(UserRepository(session), raw_id_token="google-owner")
        assert created.user.email == "google-owner@example.com"

        with database.session() as session:
            returning = service.google_login(UserRepository(session), raw_id_token="google-owner")
        assert returning.user.id == created.user.id

        with (
            database.session() as session,
            pytest.raises(AuthenticationError, match="Google identity token is invalid"),
        ):
            service.google_login(UserRepository(session), raw_id_token="google-email-collision")

        with database.session() as session, pytest.raises(RegistrationCapacityError):
            service.google_login(UserRepository(session), raw_id_token="at-capacity")

        with database.session() as session:
            user_count = session.scalar(select(func.count()).select_from(User))
        assert user_count == 2
    finally:
        database.dispose()


def test_google_login_is_explicitly_unavailable_without_client_ids(
    client: TestClient,
) -> None:
    response = client.post("/api/v1/auth/google", json={"id_token": "x" * 120})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "GOOGLE_AUTH_UNAVAILABLE"


def test_google_transport_failure_is_reported_as_temporarily_unavailable(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def fail_offline(*_: object, **__: object) -> None:
        raise google_exceptions.TransportError("synthetic offline provider")

    monkeypatch.setattr(auth_service_module.google_id_token, "verify_oauth2_token", fail_offline)
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{(tmp_path / 'google-offline.db').as_posix()}",
        allowed_origins=(),
        enable_ai_context=False,
        auth_secret_key="test-only-google-auth-secret-0123456789abcdef",
        google_oauth_client_ids=("test-client-id",),
    )
    with TestClient(create_app(settings)) as google_client:
        response = google_client.post("/api/v1/auth/google", json={"id_token": "x" * 120})

    assert response.status_code == 503
    assert response.json()["error"] == {
        "code": "GOOGLE_AUTH_UNAVAILABLE",
        "message": "Google sign-in is temporarily unavailable",
    }


def test_invalid_google_identity_remains_a_generic_auth_failure(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def reject_identity(*_: object, **__: object) -> None:
        raise ValueError("synthetic invalid signature")

    monkeypatch.setattr(auth_service_module.google_id_token, "verify_oauth2_token", reject_identity)
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{(tmp_path / 'google-invalid.db').as_posix()}",
        allowed_origins=(),
        enable_ai_context=False,
        auth_secret_key="test-only-google-auth-secret-0123456789abcdef",
        google_oauth_client_ids=("test-client-id",),
    )
    with TestClient(create_app(settings)) as google_client:
        response = google_client.post("/api/v1/auth/google", json={"id_token": "x" * 120})

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "INVALID_GOOGLE_IDENTITY"
    assert "signature" not in response.text


def test_auth_validation_rejects_weak_password_and_unknown_fields(
    client: TestClient,
) -> None:
    response = client.post(
        "/api/v1/auth/register",
        json={
            "email": "person@example.com",
            "password": "allletters",
            "display_name": "Test Person",
            "role": "admin",
        },
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_ERROR"
    assert "allletters" not in response.text


def test_account_deletion_requires_identity_and_password(client: TestClient) -> None:
    registered = _register(client)
    route = "/api/v1/auth/account/delete"
    unauthorized = client.post(route, json={"confirmation": "DELETE"})
    assert unauthorized.status_code == 401

    headers = {"Authorization": f"Bearer {registered['access_token']}"}
    wrong_password = client.post(
        route,
        headers=headers,
        json={"confirmation": "DELETE", "password": "wrong-password"},
    )
    assert wrong_password.status_code == 401

    deleted = client.post(
        route,
        headers=headers,
        json={"confirmation": "DELETE", "password": "correct-horse-42"},
    )
    assert deleted.status_code == 200
    assert deleted.json() == {"deleted": True}
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 401
    assert (
        client.post(
            "/api/v1/auth/login",
            json={"email": "person@example.com", "password": "correct-horse-42"},
        ).status_code
        == 401
    )
