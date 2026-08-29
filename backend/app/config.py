from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from dotenv import load_dotenv

BACKEND_DIRECTORY = Path(__file__).resolve().parents[1]
PROJECT_DIRECTORY = BACKEND_DIRECTORY.parent
BACKEND_ENV_FILE = BACKEND_DIRECTORY / ".env"
PROJECT_ENV_FILE = PROJECT_DIRECTORY / ".env"
GEMINI_MODEL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
LOG_LEVELS = frozenset({"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"})
MAX_CONFIGURED_SCREENSHOT_BYTES = 2_000_000
MAX_ASSESSMENT_RETENTION_DAYS = 365
MAX_CONFIGURED_ASSESSED_RECORDS_TOTAL = 100_000
MAX_CONFIGURED_ASSESSED_RECORDS_PER_DEVICE = 1_000
MAX_CONFIGURED_REGISTERED_USERS = 100_000
DEVELOPMENT_AUTH_SECRET = "development-only-auth-secret-change-before-production"
DOCUMENTED_AUTH_SECRET_PLACEHOLDER = "replace-with-at-least-32-random-characters"


def _load_environment_files() -> None:
    # Explicit process environment always wins. A backend-local file is the closest override.
    load_dotenv(BACKEND_ENV_FILE, override=False)
    load_dotenv(PROJECT_ENV_FILE, override=False)


def _as_bool(value: str | None, *, default: bool) -> bool:
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"Expected a boolean environment value, received {value!r}")


def _origins(value: str | None, *, environment: str) -> tuple[str, ...]:
    if value:
        origins = tuple(origin.strip().rstrip("/") for origin in value.split(",") if origin.strip())
    elif environment == "development":
        origins = (
            "http://localhost",
            "http://localhost:3000",
            "http://localhost:8080",
            "http://127.0.0.1:8080",
        )
    else:
        origins = ()

    return origins


def _validate_origins(origins: tuple[str, ...], *, environment: str) -> None:
    for origin in origins:
        parsed = urlsplit(origin)
        try:
            port = parsed.port
        except ValueError as exc:
            raise ValueError(f"ALLOWED_ORIGINS contains an invalid origin: {origin!r}") from exc
        if (
            "*" in origin
            or parsed.scheme.lower() not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
            or (port is not None and not 1 <= port <= 65_535)
        ):
            raise ValueError(f"ALLOWED_ORIGINS contains an invalid origin: {origin!r}")
        if environment == "production" and parsed.scheme.lower() != "https":
            raise ValueError("ALLOWED_ORIGINS must contain only HTTPS origins in production")


@dataclass(frozen=True, slots=True)
class Settings:
    app_env: str = "development"
    database_url: str = "sqlite:///./finguard.db"
    allowed_origins: tuple[str, ...] = (
        "http://localhost",
        "http://localhost:3000",
        "http://localhost:8080",
        "http://127.0.0.1:8080",
    )
    gemini_api_key: str | None = None
    gemini_model: str = "gemini-2.5-flash-lite"
    enable_ai_context: bool = False
    gemini_timeout_seconds: float = 12.0
    max_screenshot_bytes: int = 2_000_000
    assessment_retention_days: int = 30
    max_assessed_records_total: int = 5_000
    max_assessed_records_per_device: int = 50
    auth_secret_key: str = DEVELOPMENT_AUTH_SECRET
    access_token_minutes: int = 15
    refresh_token_days: int = 30
    max_registered_users: int = 5_000
    google_oauth_client_ids: tuple[str, ...] = ()
    log_level: str = "INFO"

    def __post_init__(self) -> None:
        if self.app_env not in {"development", "test", "production"}:
            raise ValueError("APP_ENV must be development, test, or production")
        if not self.database_url or not self.database_url.startswith(
            ("sqlite:", "sqlite+pysqlite:")
        ):
            raise ValueError("DATABASE_URL must be a SQLite URL")
        _validate_origins(self.allowed_origins, environment=self.app_env)
        if not GEMINI_MODEL_PATTERN.fullmatch(self.gemini_model):
            raise ValueError("GEMINI_MODEL contains unsupported characters")
        if self.enable_ai_context and (not self.gemini_api_key or not self.gemini_api_key.strip()):
            raise ValueError("GEMINI_API_KEY must be configured when ENABLE_AI_CONTEXT is true")
        if not math.isfinite(self.gemini_timeout_seconds) or not (
            1 <= self.gemini_timeout_seconds <= 60
        ):
            raise ValueError("GEMINI_TIMEOUT_SECONDS must be between 1 and 60")
        if not 1 <= self.max_screenshot_bytes <= MAX_CONFIGURED_SCREENSHOT_BYTES:
            raise ValueError(
                f"MAX_SCREENSHOT_BYTES must be between 1 and {MAX_CONFIGURED_SCREENSHOT_BYTES}"
            )
        if not 1 <= self.assessment_retention_days <= MAX_ASSESSMENT_RETENTION_DAYS:
            raise ValueError(
                f"ASSESSMENT_RETENTION_DAYS must be between 1 and {MAX_ASSESSMENT_RETENTION_DAYS}"
            )
        if not 1 <= self.max_assessed_records_total <= MAX_CONFIGURED_ASSESSED_RECORDS_TOTAL:
            raise ValueError(
                "MAX_ASSESSED_RECORDS_TOTAL must be between 1 and "
                f"{MAX_CONFIGURED_ASSESSED_RECORDS_TOTAL}"
            )
        if not (
            1 <= self.max_assessed_records_per_device <= MAX_CONFIGURED_ASSESSED_RECORDS_PER_DEVICE
        ):
            raise ValueError(
                "MAX_ASSESSED_RECORDS_PER_DEVICE must be between 1 and "
                f"{MAX_CONFIGURED_ASSESSED_RECORDS_PER_DEVICE}"
            )
        if self.max_assessed_records_per_device > self.max_assessed_records_total:
            raise ValueError(
                "MAX_ASSESSED_RECORDS_PER_DEVICE cannot exceed MAX_ASSESSED_RECORDS_TOTAL"
            )
        if len(self.auth_secret_key.strip()) < 32:
            raise ValueError("AUTH_SECRET_KEY must contain at least 32 characters")
        if self.app_env == "production" and self.auth_secret_key in {
            DEVELOPMENT_AUTH_SECRET,
            DOCUMENTED_AUTH_SECRET_PLACEHOLDER,
        }:
            raise ValueError(
                "AUTH_SECRET_KEY must replace every documented placeholder in production"
            )
        if not 5 <= self.access_token_minutes <= 60:
            raise ValueError("ACCESS_TOKEN_MINUTES must be between 5 and 60")
        if not 1 <= self.refresh_token_days <= 90:
            raise ValueError("REFRESH_TOKEN_DAYS must be between 1 and 90")
        if not 1 <= self.max_registered_users <= MAX_CONFIGURED_REGISTERED_USERS:
            raise ValueError(
                f"MAX_REGISTERED_USERS must be between 1 and {MAX_CONFIGURED_REGISTERED_USERS}"
            )
        if any(
            not client_id.strip() or len(client_id) > 255
            for client_id in self.google_oauth_client_ids
        ):
            raise ValueError("GOOGLE_OAUTH_CLIENT_IDS contains an invalid client ID")
        if self.log_level not in LOG_LEVELS:
            raise ValueError(f"LOG_LEVEL must be one of {', '.join(sorted(LOG_LEVELS))}")

    @classmethod
    def from_env(cls) -> Settings:
        _load_environment_files()
        environment = os.getenv("APP_ENV", "development").strip().lower()
        api_key = os.getenv("GEMINI_API_KEY", "").strip() or None
        return cls(
            app_env=environment,
            database_url=os.getenv("DATABASE_URL", "sqlite:///./finguard.db").strip(),
            allowed_origins=_origins(os.getenv("ALLOWED_ORIGINS"), environment=environment),
            gemini_api_key=api_key,
            gemini_model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash-lite").strip(),
            enable_ai_context=_as_bool(os.getenv("ENABLE_AI_CONTEXT"), default=False),
            gemini_timeout_seconds=float(os.getenv("GEMINI_TIMEOUT_SECONDS", "12")),
            max_screenshot_bytes=int(os.getenv("MAX_SCREENSHOT_BYTES", "2000000")),
            assessment_retention_days=int(os.getenv("ASSESSMENT_RETENTION_DAYS", "30")),
            max_assessed_records_total=int(os.getenv("MAX_ASSESSED_RECORDS_TOTAL", "5000")),
            max_assessed_records_per_device=int(os.getenv("MAX_ASSESSED_RECORDS_PER_DEVICE", "50")),
            auth_secret_key=os.getenv("AUTH_SECRET_KEY", DEVELOPMENT_AUTH_SECRET).strip(),
            access_token_minutes=int(os.getenv("ACCESS_TOKEN_MINUTES", "15")),
            refresh_token_days=int(os.getenv("REFRESH_TOKEN_DAYS", "30")),
            max_registered_users=int(os.getenv("MAX_REGISTERED_USERS", "5000")),
            google_oauth_client_ids=tuple(
                client_id.strip()
                for client_id in os.getenv("GOOGLE_OAUTH_CLIENT_IDS", "").split(",")
                if client_id.strip()
            ),
            log_level=os.getenv("LOG_LEVEL", "INFO").strip().upper(),
        )
