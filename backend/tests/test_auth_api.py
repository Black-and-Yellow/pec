from __future__ import annotations

from fastapi.testclient import TestClient


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

    refreshed = client.post(
        "/api/v1/auth/refresh", json={"refresh_token": original_refresh}
    )
    assert refreshed.status_code == 200
    replacement = refreshed.json()["refresh_token"]
    assert replacement != original_refresh

    replay = client.post(
        "/api/v1/auth/refresh", json={"refresh_token": original_refresh}
    )
    assert replay.status_code == 401

    logout = client.post("/api/v1/auth/logout", json={"refresh_token": replacement})
    assert logout.status_code == 200
    assert logout.json() == {"revoked": True}
    assert (
        client.post("/api/v1/auth/refresh", json={"refresh_token": replacement}).status_code
        == 401
    )


def test_google_login_is_explicitly_unavailable_without_client_ids(
    client: TestClient,
) -> None:
    response = client.post(
        "/api/v1/auth/google", json={"id_token": "x" * 120}
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "GOOGLE_AUTH_UNAVAILABLE"


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
