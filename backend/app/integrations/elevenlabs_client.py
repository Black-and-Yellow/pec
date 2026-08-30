"""Text-to-speech for statements FinGuard has already written.

This client speaks; it never composes. The text it receives comes from
app.services.voice_statements, which is a fixed table, so nothing a payer or a
payee controls reaches the provider and no provider response can change what
FinGuard claims about a payment. The only thing that can go wrong here is
silence, which the caller is expected to handle.
"""

from __future__ import annotations

from typing import Final

import httpx

_API_ROOT: Final[str] = "https://api.elevenlabs.io/v1/text-to-speech"

#: Multilingual stock voices, one per offered language.
#:
#: ElevenLabs' multilingual models carry the language in the text itself rather
#: than in the voice, so a single voice can read all five. They are named
#: separately anyway: a voice that suits Hindi prosody can sound wrong reading
#: Malayalam, and pinning one per language means a bad match is fixed by
#: editing one line instead of re-testing every language.
DEFAULT_VOICE_IDS: Final[dict[str, str]] = {
    "hi": "21m00Tcm4TlvDq8ikWAM",
    "ta": "21m00Tcm4TlvDq8ikWAM",
    "te": "21m00Tcm4TlvDq8ikWAM",
    "kn": "21m00Tcm4TlvDq8ikWAM",
    "ml": "21m00Tcm4TlvDq8ikWAM",
}

MPEG_MIME_TYPE: Final[str] = "audio/mpeg"

#: A spoken verdict is three sentences. Anything far larger means a caller has
#: been handed text this module was never meant to read aloud.
MAX_SPEAKABLE_CHARACTERS: Final[int] = 1_200


class ElevenLabsUnavailable(RuntimeError):
    """The provider could not complete the request."""


class ElevenLabsMalformedResponse(RuntimeError):
    """The provider returned something that was not playable audio."""


class ElevenLabsClient:
    def __init__(self, *, api_key: str, model: str, timeout_seconds: float) -> None:
        self._api_key = api_key
        self._model = model
        self._timeout_seconds = timeout_seconds

    async def synthesize(self, *, text: str, language: str) -> bytes:
        """Render one fixed statement to MP3 bytes."""
        if not text.strip():
            raise ElevenLabsMalformedResponse("Refusing to synthesize empty text")
        if len(text) > MAX_SPEAKABLE_CHARACTERS:
            raise ElevenLabsMalformedResponse("Text exceeds the speakable length limit")

        voice_id = DEFAULT_VOICE_IDS.get(language)
        if voice_id is None:
            raise ElevenLabsMalformedResponse(f"No configured voice for language {language!r}")

        payload = {
            "text": text,
            "model_id": self._model,
            # Steady delivery matters more than expressiveness here: this is a
            # safety warning, and a voice that varies its emphasis run to run
            # makes the same verdict sound like two different verdicts.
            "voice_settings": {"stability": 0.6, "similarity_boost": 0.75},
        }
        try:
            async with httpx.AsyncClient(timeout=self._timeout_seconds) as client:
                response = await client.post(
                    f"{_API_ROOT}/{voice_id}",
                    headers={
                        "xi-api-key": self._api_key,
                        "Content-Type": "application/json",
                        "Accept": MPEG_MIME_TYPE,
                    },
                    json=payload,
                )
            response.raise_for_status()
        except (httpx.HTTPError, httpx.TimeoutException) as exc:
            raise ElevenLabsUnavailable("Voice synthesis is temporarily unavailable") from exc

        audio = response.content
        # An error page returned with a 200 would otherwise reach the phone as
        # a file that silently fails to play, which looks like a broken app
        # rather than a provider problem.
        if not audio or not response.headers.get("content-type", "").startswith("audio/"):
            raise ElevenLabsMalformedResponse("Provider returned a non-audio response")
        return audio
