from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.integrations.elevenlabs_client import (
    ElevenLabsMalformedResponse,
    ElevenLabsUnavailable,
)
from app.main import create_app
from app.schemas import RiskLevel
from app.services.voice_service import VoiceService, VoiceUnavailable
from app.services.voice_statements import SUPPORTED_LANGUAGES, statement_for


class StubClient:
    """Stands in for the provider so no test reaches the network."""

    def __init__(self, *, audio: bytes = b"ID3fake-mp3-bytes", failure: Exception | None = None):
        self.audio = audio
        self.failure = failure
        self.calls: list[tuple[str, str]] = []

    async def synthesize(self, *, text: str, language: str) -> bytes:
        self.calls.append((text, language))
        if self.failure is not None:
            raise self.failure
        return self.audio


def _service(tmp_path: Path, client: StubClient | None, *, enabled: bool = True) -> VoiceService:
    return VoiceService(
        client=client,  # type: ignore[arg-type]
        cache_directory=tmp_path / "voice-cache",
        enabled=enabled,
    )


def test_every_verdict_has_a_statement_in_every_language() -> None:
    for level in RiskLevel:
        for language in SUPPORTED_LANGUAGES:
            spoken = statement_for(level=level, score=82, language=language)
            assert spoken.strip()
            assert "{score}" not in spoken


def test_the_spoken_score_is_the_score_that_was_supplied() -> None:
    spoken = statement_for(level=RiskLevel.HIGH, score=91, language="ta")
    assert "91" in spoken


def test_an_unsupported_language_is_refused() -> None:
    with pytest.raises(KeyError):
        statement_for(level=RiskLevel.SAFE, score=10, language="fr")


@pytest.mark.anyio
async def test_audio_is_synthesized_once_and_then_served_from_cache(tmp_path: Path) -> None:
    stub = StubClient()
    service = _service(tmp_path, stub)

    first = await service.speak(level=RiskLevel.HIGH, score=82, language="ta")
    second = await service.speak(level=RiskLevel.HIGH, score=82, language="ta")

    assert first == second == stub.audio
    assert len(stub.calls) == 1, "the second request must not reach the provider"


@pytest.mark.anyio
async def test_a_different_score_is_a_different_clip(tmp_path: Path) -> None:
    stub = StubClient()
    service = _service(tmp_path, stub)

    await service.speak(level=RiskLevel.HIGH, score=82, language="ta")
    await service.speak(level=RiskLevel.HIGH, score=91, language="ta")

    assert len(stub.calls) == 2
    assert "82" in stub.calls[0][0]
    assert "91" in stub.calls[1][0]


@pytest.mark.anyio
async def test_the_provider_only_ever_receives_our_own_statement(tmp_path: Path) -> None:
    stub = StubClient()
    service = _service(tmp_path, stub)

    await service.speak(level=RiskLevel.CAUTION, score=55, language="hi")

    spoken_text, language = stub.calls[0]
    assert language == "hi"
    assert spoken_text == statement_for(level=RiskLevel.CAUTION, score=55, language="hi")


@pytest.mark.anyio
@pytest.mark.parametrize(
    "failure",
    [ElevenLabsUnavailable("down"), ElevenLabsMalformedResponse("not audio")],
)
async def test_a_provider_failure_surfaces_as_voice_unavailable(
    tmp_path: Path, failure: Exception
) -> None:
    service = _service(tmp_path, StubClient(failure=failure))
    with pytest.raises(VoiceUnavailable):
        await service.speak(level=RiskLevel.HIGH, score=82, language="ta")


@pytest.mark.anyio
async def test_a_disabled_service_never_calls_the_provider(tmp_path: Path) -> None:
    stub = StubClient()
    service = _service(tmp_path, stub, enabled=False)

    with pytest.raises(VoiceUnavailable):
        await service.speak(level=RiskLevel.HIGH, score=82, language="ta")
    assert stub.calls == []


def test_the_layer_is_off_and_advertises_nothing_without_a_key(client: TestClient) -> None:
    response = client.get("/api/v1/voice/languages")

    assert response.status_code == 200
    assert response.json() == {"enabled": False, "languages": []}


def test_speaking_while_disabled_reports_the_written_result_still_applies(
    client: TestClient,
) -> None:
    response = client.post(
        "/api/v1/voice/speak",
        json={"level": "HIGH", "score": 82, "language": "ta"},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "VOICE_UNAVAILABLE"


def test_the_route_rejects_a_score_outside_the_scale(client: TestClient) -> None:
    response = client.post(
        "/api/v1/voice/speak",
        json={"level": "HIGH", "score": 101, "language": "ta"},
    )

    assert response.status_code == 422


def test_the_route_rejects_unexpected_fields(client: TestClient) -> None:
    response = client.post(
        "/api/v1/voice/speak",
        json={"level": "HIGH", "score": 82, "language": "ta", "text": "say anything"},
    )

    assert response.status_code == 422, "callers must not be able to choose the spoken words"


def test_enabling_voice_without_a_key_is_refused_at_startup() -> None:
    with pytest.raises(ValueError, match="ELEVENLABS_API_KEY"):
        Settings(app_env="test", enable_voice_assist=True, elevenlabs_api_key=None)


def test_an_enabled_deployment_offers_the_languages(tmp_path: Path) -> None:
    settings = Settings(
        app_env="test",
        database_url=f"sqlite:///{(tmp_path / 'voice.db').as_posix()}",
        allowed_origins=(),
        enable_voice_assist=True,
        elevenlabs_api_key="test-key",
    )
    with TestClient(create_app(settings)) as configured:
        payload = configured.get("/api/v1/voice/languages").json()

    assert payload["enabled"] is True
    assert [option["code"] for option in payload["languages"]] == list(SUPPORTED_LANGUAGES)
