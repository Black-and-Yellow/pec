from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def client(tmp_path) -> Iterator[TestClient]:
    database_path = (tmp_path / "finguard-test.db").as_posix()
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{database_path}",
        allowed_origins=(),
        gemini_api_key=None,
        enable_ai_context=True,
    )
    with TestClient(create_app(settings)) as test_client:
        yield test_client
