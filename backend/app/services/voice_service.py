"""Turn a verdict FinGuard already reached into spoken audio.

The service owns one decision only: which fixed statement describes this
verdict. It never scores, never re-words, and never asks a model what to say.

Synthesised audio is cached on disk because a demo, a classroom, or a queue of
people checking payments will ask for the same nine or ten clips all day, and
the second listener should not depend on the provider still being reachable.
"""

from __future__ import annotations

import hashlib
import logging
import re
from pathlib import Path
from typing import Final

from app.integrations.elevenlabs_client import (
    ElevenLabsClient,
    ElevenLabsMalformedResponse,
    ElevenLabsUnavailable,
)
from app.schemas import RiskLevel
from app.services.voice_statements import is_supported_language, statement_for

logger = logging.getLogger("finguard")

#: Cache keys are hashes we generate ourselves; this only guards against a
#: future caller passing something else into the path.
_CACHE_KEY_PATTERN: Final[re.Pattern[str]] = re.compile(r"^[0-9a-f]{32}$")


class VoiceUnavailable(RuntimeError):
    """No audio could be produced for this verdict."""


class VoiceService:
    def __init__(
        self,
        *,
        client: ElevenLabsClient | None,
        cache_directory: Path,
        enabled: bool,
    ) -> None:
        self._client = client
        self._cache_directory = cache_directory
        self._enabled = enabled and client is not None

    @property
    def enabled(self) -> bool:
        return self._enabled

    async def speak(self, *, level: RiskLevel, score: int, language: str) -> bytes:
        if not self._enabled or self._client is None:
            raise VoiceUnavailable("Voice assistance is disabled")
        if not is_supported_language(language):
            raise VoiceUnavailable(f"Unsupported language {language!r}")

        text = statement_for(level=level, score=score, language=language)
        cache_key = self._cache_key(level=level, score=score, language=language)

        cached = self._read_cache(cache_key)
        if cached is not None:
            return cached

        try:
            audio = await self._client.synthesize(text=text, language=language)
        except (ElevenLabsUnavailable, ElevenLabsMalformedResponse) as exc:
            raise VoiceUnavailable(str(exc)) from exc

        self._write_cache(cache_key, audio)
        return audio

    @staticmethod
    def _cache_key(*, level: RiskLevel, score: int, language: str) -> str:
        # The score is part of the key because it is read out. Two HIGH
        # verdicts scoring 78 and 91 are different clips, and a key that
        # ignored the number would play one person's score to another.
        raw = f"v1|{level.value}|{score}|{language}"
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]

    def _cache_path(self, cache_key: str) -> Path | None:
        if not _CACHE_KEY_PATTERN.fullmatch(cache_key):
            return None
        return self._cache_directory / f"{cache_key}.mp3"

    def _read_cache(self, cache_key: str) -> bytes | None:
        path = self._cache_path(cache_key)
        if path is None:
            return None
        try:
            if path.is_file():
                audio = path.read_bytes()
                return audio or None
        except OSError:
            # A cache that cannot be read is not a reason to refuse to speak.
            logger.warning("voice_cache_read_failed", exc_info=True)
        return None

    def _write_cache(self, cache_key: str, audio: bytes) -> None:
        path = self._cache_path(cache_key)
        if path is None:
            return
        try:
            self._cache_directory.mkdir(parents=True, exist_ok=True)
            # Written beside the target and moved into place, so a request
            # interrupted mid-write cannot leave a truncated clip that later
            # plays as a cut-off warning.
            temporary = path.with_suffix(".mp3.partial")
            temporary.write_bytes(audio)
            temporary.replace(path)
        except OSError:
            logger.warning("voice_cache_write_failed", exc_info=True)
