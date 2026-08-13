from __future__ import annotations

import json
import logging

import pytest

from app import config
from app.config import Settings
from app.logging_config import JsonFormatter


def test_dotenv_files_load_without_overriding_process_environment(
    tmp_path, monkeypatch: pytest.MonkeyPatch
) -> None:
    backend_env = tmp_path / "backend.env"
    project_env = tmp_path / "project.env"
    backend_env.write_text(
        "APP_ENV=test\n"
        "DATABASE_URL=sqlite:///from-backend-env.db\n"
        "GEMINI_MODEL=gemini-test-model\n"
        "ENABLE_AI_CONTEXT=false\n",
        encoding="utf-8",
    )
    project_env.write_text(
        "DATABASE_URL=sqlite:///from-project-env.db\n"
        "GEMINI_MODEL=ignored-project-model\n"
        "LOG_LEVEL=DEBUG\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(config, "BACKEND_ENV_FILE", backend_env)
    monkeypatch.setattr(config, "PROJECT_ENV_FILE", project_env)
    for name in (
        "APP_ENV",
        "DATABASE_URL",
        "GEMINI_MODEL",
        "ENABLE_AI_CONTEXT",
        "LOG_LEVEL",
        "MAX_ASSESSED_RECORDS_TOTAL",
        "MAX_ASSESSED_RECORDS_PER_DEVICE",
        "MAX_REGISTERED_USERS",
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("LOG_LEVEL", "ERROR")

    settings = Settings.from_env()

    assert settings.app_env == "test"
    assert settings.database_url == "sqlite:///from-backend-env.db"
    assert settings.gemini_model == "gemini-test-model"
    assert settings.enable_ai_context is False
    assert settings.log_level == "ERROR"
    assert settings.max_assessed_records_total == 5_000
    assert settings.max_assessed_records_per_device == 50
    assert settings.max_registered_users == 5_000


def test_optional_ai_defaults_to_disabled_without_provider_configuration(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config, "BACKEND_ENV_FILE", tmp_path / "missing-backend.env")
    monkeypatch.setattr(config, "PROJECT_ENV_FILE", tmp_path / "missing-project.env")
    monkeypatch.delenv("ENABLE_AI_CONTEXT", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    settings = Settings.from_env()

    assert settings.enable_ai_context is False
    assert settings.gemini_api_key is None

    monkeypatch.setenv("GEMINI_API_KEY", "test-only-provider-key")
    settings_with_key_only = Settings.from_env()
    assert settings_with_key_only.enable_ai_context is False
    assert settings_with_key_only.gemini_api_key == "test-only-provider-key"

    production_settings = Settings(
        app_env="production",
        allowed_origins=("https://finguard.example.dev",),
        auth_secret_key="production-test-secret-0123456789abcdef",
    )
    assert production_settings.enable_ai_context is False


def test_optional_ai_requires_explicit_switch_and_key(
    tmp_path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(config, "BACKEND_ENV_FILE", tmp_path / "missing-backend.env")
    monkeypatch.setattr(config, "PROJECT_ENV_FILE", tmp_path / "missing-project.env")
    monkeypatch.setenv("ENABLE_AI_CONTEXT", "true")
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    with pytest.raises(
        ValueError,
        match="GEMINI_API_KEY must be configured when ENABLE_AI_CONTEXT is true",
    ):
        Settings.from_env()

    monkeypatch.setenv("GEMINI_API_KEY", "test-only-provider-key")
    settings = Settings.from_env()

    assert settings.enable_ai_context is True
    assert settings.gemini_api_key == "test-only-provider-key"


@pytest.mark.parametrize(
    "overrides",
    [
        {"database_url": "postgresql://paid.example.invalid/finguard"},
        {"gemini_model": "model?key=unsafe"},
        {"gemini_timeout_seconds": 0},
        {"gemini_timeout_seconds": float("nan")},
        {"max_screenshot_bytes": 0},
        {"max_screenshot_bytes": 2_000_001},
        {"assessment_retention_days": 0},
        {"assessment_retention_days": 366},
        {"max_assessed_records_total": 0},
        {"max_assessed_records_total": 100_001},
        {"max_assessed_records_per_device": 0},
        {"max_assessed_records_per_device": 1_001},
        {"max_assessed_records_total": 10, "max_assessed_records_per_device": 11},
        {"auth_secret_key": "too-short"},
        {"access_token_minutes": 4},
        {"access_token_minutes": 61},
        {"refresh_token_days": 0},
        {"refresh_token_days": 91},
        {"max_registered_users": 0},
        {"max_registered_users": 100_001},
        {"app_env": "production"},
        {"log_level": "VERBOSE"},
        {"app_env": "production", "allowed_origins": ("*",)},
        {"allowed_origins": ("https://example.dev/unexpected-path",)},
        {"allowed_origins": ("file://local-app",)},
    ],
)
def test_invalid_or_unsafe_configuration_fails_fast(overrides: dict[str, object]) -> None:
    with pytest.raises(ValueError):
        Settings(**overrides)


@pytest.mark.parametrize(
    "placeholder",
    [
        config.DEVELOPMENT_AUTH_SECRET,
        config.DOCUMENTED_AUTH_SECRET_PLACEHOLDER,
    ],
)
def test_production_rejects_every_documented_auth_secret_placeholder(
    placeholder: str,
) -> None:
    with pytest.raises(
        ValueError,
        match="must replace every documented placeholder",
    ):
        Settings(
            app_env="production",
            allowed_origins=("https://finguard.example.dev",),
            auth_secret_key=placeholder,
        )


@pytest.mark.parametrize(
    "origins",
    [
        ("http://finguard.example.dev",),
        ("HTTP://finguard.example.dev",),
        ("http://localhost:8080",),
        ("https://finguard.example.dev", "http://assets.example.dev"),
    ],
)
def test_production_rejects_every_non_https_cors_origin(
    origins: tuple[str, ...],
) -> None:
    with pytest.raises(
        ValueError, match="ALLOWED_ORIGINS must contain only HTTPS origins in production"
    ):
        Settings(
            app_env="production",
            allowed_origins=origins,
            auth_secret_key="production-test-secret-0123456789abcdef",
        )


@pytest.mark.parametrize("environment", ["development", "test"])
def test_non_production_environments_retain_local_http_cors(
    environment: str,
) -> None:
    settings = Settings(
        app_env=environment,
        allowed_origins=("http://localhost:8080", "http://127.0.0.1:8000"),
    )

    assert settings.allowed_origins == (
        "http://localhost:8080",
        "http://127.0.0.1:8000",
    )


def test_structured_log_formatter_uses_safe_request_metadata() -> None:
    record = logging.LogRecord(
        name="finguard",
        level=logging.INFO,
        pathname=__file__,
        lineno=1,
        msg="request_complete",
        args=(),
        exc_info=None,
    )
    record.request_id = "request-123"
    record.method = "POST"
    record.path = "/api/v1/risk/score"
    record.status = 200
    record.duration_ms = 4.2

    payload = json.loads(JsonFormatter().format(record))

    assert payload["event"] == "request_complete"
    assert payload["path"] == "/api/v1/risk/score"
    assert payload["status"] == 200
    assert payload["duration_ms"] == 4.2
    assert set(payload) == {
        "timestamp",
        "level",
        "event",
        "request_id",
        "method",
        "path",
        "status",
        "duration_ms",
    }
