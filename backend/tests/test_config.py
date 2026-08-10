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
    ):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("LOG_LEVEL", "ERROR")

    settings = Settings.from_env()

    assert settings.app_env == "test"
    assert settings.database_url == "sqlite:///from-backend-env.db"
    assert settings.gemini_model == "gemini-test-model"
    assert settings.enable_ai_context is False
    assert settings.log_level == "ERROR"


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
        {"auth_secret_key": "too-short"},
        {"access_token_minutes": 4},
        {"access_token_minutes": 61},
        {"refresh_token_days": 0},
        {"refresh_token_days": 91},
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
