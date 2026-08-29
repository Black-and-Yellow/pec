from __future__ import annotations

import secrets
from datetime import UTC, datetime
from typing import Literal, TypeAlias

import jwt
from jwt import InvalidTokenError
from pydantic import BaseModel, ConfigDict, Field, StrictInt, ValidationError

from app.schemas import ContextSignals

CONTEXT_TOKEN_ISSUER: Literal["finguard-context-analyzer"] = "finguard-context-analyzer"
CONTEXT_TOKEN_AUDIENCE: Literal["finguard-risk-engine"] = "finguard-risk-engine"
CONTEXT_TOKEN_TYPE: Literal["context_integrity"] = "context_integrity"
CONTEXT_TOKEN_TTL_SECONDS = 300
_REQUIRED_CLAIMS = frozenset(
    {"iss", "aud", "iat", "exp", "jti", "type", "source", "context"}
)
ContextProvenance: TypeAlias = Literal["gemini", "local_rules", "demo"]


class _ContextTokenClaims(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    iss: Literal["finguard-context-analyzer"]
    aud: Literal["finguard-risk-engine"]
    iat: StrictInt
    exp: StrictInt
    jti: str = Field(pattern=r"^[0-9a-f]{32}$")
    type: Literal["context_integrity"]
    source: ContextProvenance
    context: ContextSignals


class ContextIntegrityError(ValueError):
    pass


class ContextIntegrityService:
    """Issue and verify bounded proof that context crossed the server analyzer."""

    def __init__(self, secret_key: str) -> None:
        self._secret_key = secret_key

    def issue(self, context: ContextSignals, *, provenance: ContextProvenance) -> str:
        normalized = ContextSignals.model_validate(context.model_dump(mode="json"))
        issued_at = int(datetime.now(UTC).timestamp())
        claims = _ContextTokenClaims(
            iss=CONTEXT_TOKEN_ISSUER,
            aud=CONTEXT_TOKEN_AUDIENCE,
            iat=issued_at,
            exp=issued_at + CONTEXT_TOKEN_TTL_SECONDS,
            jti=secrets.token_hex(16),
            type=CONTEXT_TOKEN_TYPE,
            source=provenance,
            context=normalized,
        )
        return jwt.encode(
            claims.model_dump(mode="json"),
            self._secret_key,
            algorithm="HS256",
        )

    def context_for_score(
        self,
        context: ContextSignals | None,
        raw_token: str | None,
    ) -> ContextSignals | None:
        if context is None and raw_token is None:
            return None
        if context is None or raw_token is None:
            raise ContextIntegrityError("Context and integrity token must be supplied together")

        verified = self.verify(raw_token)
        if verified != context:
            raise ContextIntegrityError("Context does not match its integrity token")
        return verified

    def verify(self, raw_token: str) -> ContextSignals:
        try:
            raw_claims = jwt.decode(
                raw_token,
                self._secret_key,
                algorithms=["HS256"],
                audience=CONTEXT_TOKEN_AUDIENCE,
                issuer=CONTEXT_TOKEN_ISSUER,
                options={"require": sorted(_REQUIRED_CLAIMS)},
            )
            claims = _ContextTokenClaims.model_validate(raw_claims)
            if (
                claims.exp <= claims.iat
                or claims.exp - claims.iat > CONTEXT_TOKEN_TTL_SECONDS
            ):
                raise ContextIntegrityError("Context token lifetime is invalid")
            return claims.context
        except ContextIntegrityError:
            raise
        except (InvalidTokenError, ValidationError, TypeError, ValueError) as exc:
            raise ContextIntegrityError("Context token is invalid or expired") from exc
