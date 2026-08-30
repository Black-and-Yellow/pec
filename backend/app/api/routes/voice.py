"""Read a verdict aloud for someone who cannot read it.

This route is additive and optional. It reads the level and score the risk
engine already produced and returns audio of a fixed statement describing
them. It scores nothing, stores nothing about the payment, and is never on the
path between a payer and their decision: if it fails, the screen the caller is
already looking at is unchanged.

The request schema lives here rather than in app.schemas because nothing else
in the API refers to it, and keeping it local means the shared contract the
app parses strictly cannot be disturbed by a change made for the voice layer.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import ConfigDict, Field

from app.integrations.elevenlabs_client import MPEG_MIME_TYPE
from app.schemas import RiskLevel, StrictModel
from app.services.voice_service import VoiceService, VoiceUnavailable
from app.services.voice_statements import SUPPORTED_LANGUAGES

router = APIRouter(prefix="/voice", tags=["voice"])


def get_voice_service(request: Request) -> VoiceService:
    return request.app.state.voice_service


class VoiceSpeakRequest(StrictModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    level: RiskLevel
    score: int = Field(ge=0, le=100)
    language: str = Field(min_length=2, max_length=8)


class VoiceLanguageOption(StrictModel):
    code: str
    label: str


class VoiceLanguagesResponse(StrictModel):
    enabled: bool
    languages: list[VoiceLanguageOption]


@router.get("/languages", response_model=VoiceLanguagesResponse)
def voice_languages(
    voice: Annotated[VoiceService, Depends(get_voice_service)],
) -> VoiceLanguagesResponse:
    """Report whether the voice layer is available, and in which languages.

    The app asks this before drawing a listen control, so a deployment with no
    provider key simply never offers a button that could not work.
    """
    return VoiceLanguagesResponse(
        enabled=voice.enabled,
        languages=[
            VoiceLanguageOption(code=code, label=label)
            for code, label in SUPPORTED_LANGUAGES.items()
        ]
        if voice.enabled
        else [],
    )


@router.post(
    "/speak",
    responses={200: {"content": {MPEG_MIME_TYPE: {}}}},
    response_class=Response,
)
async def speak_verdict(
    request: VoiceSpeakRequest,
    voice: Annotated[VoiceService, Depends(get_voice_service)],
) -> Response:
    try:
        audio = await voice.speak(
            level=request.level,
            score=request.score,
            language=request.language,
        )
    except VoiceUnavailable as exc:
        # 503 rather than 500: nothing was wrong with the request, and the
        # caller is expected to fall back to the text already on screen.
        raise HTTPException(
            status_code=503,
            detail={
                "code": "VOICE_UNAVAILABLE",
                "message": "Spoken guidance is unavailable; the written result still applies",
            },
        ) from exc

    return Response(
        content=audio,
        media_type=MPEG_MIME_TYPE,
        headers={"Cache-Control": "no-store"},
    )
