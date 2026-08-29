from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from collections.abc import Iterator
from pathlib import Path

import httpx
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
        enable_ai_context=False,
    )
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def _available_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


@pytest.fixture(scope="session")
def live_api_url(tmp_path_factory: pytest.TempPathFactory) -> Iterator[str]:
    """Run the production ASGI entry point through a real local Uvicorn process."""
    backend_directory = Path(__file__).resolve().parents[1]
    runtime_directory = tmp_path_factory.mktemp("live-api")
    database_path = (runtime_directory / "finguard-live-test.db").as_posix()
    log_path = runtime_directory / "uvicorn.log"
    port = _available_local_port()
    base_url = f"http://127.0.0.1:{port}"

    environment = os.environ.copy()
    environment.update(
        {
            "ALLOWED_ORIGINS": "",
            "APP_ENV": "test",
            "AUTH_SECRET_KEY": "test-only-live-auth-secret-0123456789abcdef",
            "DATABASE_URL": f"sqlite:///{database_path}",
            "ENABLE_AI_CONTEXT": "false",
            "GEMINI_API_KEY": "",
            "GOOGLE_OAUTH_CLIENT_IDS": "",
            "PYTHONUNBUFFERED": "1",
        }
    )

    with log_path.open("w+", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "--log-level",
                "warning",
            ],
            cwd=backend_directory,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 20
            with httpx.Client(base_url=base_url, timeout=0.5, trust_env=False) as probe:
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        break
                    try:
                        if probe.get("/api/v1/health").status_code == 200:
                            yield base_url
                            return
                    except httpx.HTTPError:
                        pass
                    time.sleep(0.05)

            log_file.flush()
            log_file.seek(0)
            diagnostics = log_file.read()[-4_000:]
            raise RuntimeError(f"Uvicorn did not become healthy: {diagnostics}")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
