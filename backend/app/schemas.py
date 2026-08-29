from __future__ import annotations

import re
from datetime import datetime
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictBool,
    StringConstraints,
    field_serializer,
    field_validator,
    model_validator,
)

VPA_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}@[A-Za-z0-9][A-Za-z0-9.-]{0,63}$")
DEVICE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{2,127}$")
MAX_PAYMENT_AMOUNT = Decimal("10000000")

DeviceId = Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=128)]
AssessmentId = Annotated[
    str,
    StringConstraints(
        strip_whitespace=True,
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$",
    ),
]
ContextToken = Annotated[
    str,
    StringConstraints(strip_whitespace=True, min_length=1, max_length=4_096),
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class RiskLevel(StrEnum):
    SAFE = "SAFE"
    CAUTION = "CAUTION"
    HIGH = "HIGH"


class PaymentDetails(StrictModel):
    vpa: str = Field(min_length=3, max_length=193)
    payee_name: str | None = Field(default=None, max_length=128)
    amount: Decimal | None = Field(default=None, gt=0, le=MAX_PAYMENT_AMOUNT)
    transaction_note: str | None = Field(default=None, max_length=250)
    currency: str = Field(default="INR", pattern=r"^[A-Z]{3}$")
    transaction_reference: str | None = Field(default=None, max_length=100)

    @field_validator("vpa")
    @classmethod
    def normalize_vpa(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not VPA_PATTERN.fullmatch(normalized):
            raise ValueError("vpa must be a valid UPI virtual payment address")
        return normalized

    @field_validator("currency")
    @classmethod
    def require_inr(cls, value: str) -> str:
        normalized = value.upper()
        if normalized != "INR":
            raise ValueError("FinGuard currently supports INR UPI requests only")
        return normalized

    @field_validator("amount")
    @classmethod
    def require_currency_precision(cls, value: Decimal | None) -> Decimal | None:
        if value is not None:
            exponent = value.as_tuple().exponent
            if isinstance(exponent, int) and exponent < -2:
                raise ValueError("amount must have at most two decimal places")
        return value

    @field_validator("payee_name", "transaction_note", "transaction_reference")
    @classmethod
    def reject_control_characters(cls, value: str | None) -> str | None:
        if value is None:
            return None
        if any(ord(character) < 32 or ord(character) == 127 for character in value):
            raise ValueError("control characters are not allowed")
        cleaned = " ".join(value.split())
        return cleaned or None

    @field_serializer("amount", when_used="json")
    def serialize_amount(self, value: Decimal | None) -> float | None:
        return float(value) if value is not None else None


class ParsePaymentRequest(StrictModel):
    upi_uri: str = Field(min_length=1, max_length=2_048)


class QrProvenance(StrictModel):
    """Presence-only hints reported from an untrusted UPI QR payload.

    These booleans do not establish who issued a QR or whether any signature is
    authentic. Keeping only presence prevents opaque QR metadata from crossing
    the API boundary while still allowing deterministic policy to raise risk.
    """

    sign_present: StrictBool = False
    orgid_present: StrictBool = False
    mode_present: StrictBool = False
    merchant_category_present: StrictBool = False


class ParsePaymentResponse(StrictModel):
    payment: PaymentDetails
    canonical_uri: str
    qr_provenance: QrProvenance


class ContextSignals(StrictModel):
    impersonation: StrictBool
    urgency: StrictBool
    kyc_threat: StrictBool
    reward_or_refund_claim: StrictBool
    payment_requested: StrictBool
    suspicious_support_claim: StrictBool
    confidence: float = Field(ge=0, le=1, strict=True)


class ContextAnalyzeRequest(StrictModel):
    text: str | None = Field(default=None, max_length=5_000)
    screenshot_base64: str | None = Field(default=None, max_length=2_700_000)
    screenshot_mime_type: Literal["image/png", "image/jpeg", "image/webp"] | None = None
    consent_to_external_ai: StrictBool = False

    @field_validator("text")
    @classmethod
    def normalize_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        return value or None

    @model_validator(mode="after")
    def validate_content(self) -> ContextAnalyzeRequest:
        if self.text is None and self.screenshot_base64 is None:
            raise ValueError("provide text or a base64-encoded screenshot")
        if (self.screenshot_base64 is None) != (self.screenshot_mime_type is None):
            raise ValueError("screenshot_base64 and screenshot_mime_type must be provided together")
        return self


class ContextAnalyzeResponse(StrictModel):
    available: bool
    source: Literal["gemini", "local_rules", "none"]
    status: Literal[
        "analyzed",
        "ai_disabled",
        "consent_required",
        "provider_unavailable",
        "malformed_response",
    ]
    message: str
    context: ContextSignals
    context_token: ContextToken | None = None


class RiskSignal(StrictModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_]+$", max_length=64)
    label: str = Field(min_length=1, max_length=160)
    weight: int = Field(ge=0, le=100)
    evidence: str = Field(min_length=1, max_length=300)


class RemoteAccessTool(StrEnum):
    """Remote-desktop tooling that fraudsters direct victims to install.

    The client reports only these fixed identifiers; the server owns the
    display names, so a compromised client cannot inject text into evidence.
    """

    ANYDESK = "ANYDESK"
    TEAMVIEWER = "TEAMVIEWER"
    RUSTDESK = "RUSTDESK"
    AIRDROID = "AIRDROID"
    OTHER = "OTHER"


class CallActivity(StrEnum):
    """Whether a voice call was in progress when the check ran.

    Read once, synchronously, at the moment the user starts a check. FinGuard
    does not listen in the background and cannot see a call that starts after
    a result is already on screen.
    """

    NONE = "NONE"
    CELLULAR = "CELLULAR"
    """A normal phone call, reported by the telephony call state."""

    VOICE_OVER_IP = "VOICE_OVER_IP"
    """A WhatsApp, Telegram, or similar in-app call, reported by audio mode."""

    RINGING = "RINGING"
    """An incoming call is ringing but has not been answered."""

    UNKNOWN = "UNKNOWN"
    """A call is active but the platform would not say which kind."""


ACTIVE_CALL_STATES: frozenset[CallActivity] = frozenset(
    {
        CallActivity.CELLULAR,
        CallActivity.VOICE_OVER_IP,
        CallActivity.UNKNOWN,
    }
)


class EnvironmentSignals(StrictModel):
    """Device-environment facts observed by the client at check time.

    These are self-reported observations, not attested claims. They can only
    raise risk, never lower it, so a client that under-reports harms only
    itself and one that over-reports cannot suppress a real warning.
    """

    remote_access_tools: list[RemoteAccessTool] = Field(default_factory=list, max_length=8)
    call_activity: CallActivity = CallActivity.NONE


class TrustGrade(StrEnum):
    """Bands for the payee trust score, read the way a credit grade is read."""

    A_PLUS = "A_PLUS"
    A = "A"
    B = "B"
    C = "C"
    D = "D"
    NEW = "NEW"
    """A thin file: too little history to grade, which is not the same as bad."""


class TrustPillarStatus(StrEnum):
    STRONG = "STRONG"
    NEUTRAL = "NEUTRAL"
    WEAK = "WEAK"
    NO_DATA = "NO_DATA"


class TrustPillarCode(StrEnum):
    IDENTITY = "IDENTITY"
    TENURE = "TENURE"
    REACH = "REACH"
    CONDUCT = "CONDUCT"
    VELOCITY = "VELOCITY"


class TrustPillar(StrictModel):
    code: TrustPillarCode
    label: str = Field(min_length=1, max_length=80)
    points: int = Field(ge=0, le=100)
    maximum: int = Field(ge=1, le=100)
    status: TrustPillarStatus
    evidence: str = Field(min_length=1, max_length=400)


class PayeeTrust(StrictModel):
    """A reputation report for one UPI ID, assembled from what FinGuard can see.

    This is a FinGuard network score. It is not an NPCI rating, not a bank
    rating, and not a credit bureau score. The disclaimer travels with the
    payload so no surface can render the number without its provenance.
    """

    vpa: str = Field(min_length=3, max_length=193)
    score: int | None = Field(default=None, ge=0, le=100)
    """Withheld for a thin file, the way a bureau returns NH instead of a number.

    A new payee that scored well on address structure alone would otherwise
    display a high number beside a NEW grade, which reads as an endorsement
    of an address nobody has ever met.
    """

    grade: TrustGrade
    headline: str = Field(min_length=1, max_length=160)
    thin_file: bool
    impersonation: bool
    confidence: Literal["LOW", "MEDIUM", "HIGH"]
    pillars: list[TrustPillar] = Field(max_length=8)
    assessed_points: int = Field(ge=0, le=100)
    assessable_maximum: int = Field(ge=1, le=100)
    first_seen_at: datetime | None = None
    observed_days: int = Field(ge=0)
    check_count: int = Field(ge=0)
    distinct_device_count: int = Field(ge=0)
    reported_count: int = Field(ge=0)
    disclaimer: str = Field(min_length=1, max_length=400)


class TrustLookupRequest(StrictModel):
    vpa: str = Field(min_length=3, max_length=193)

    @field_validator("vpa")
    @classmethod
    def normalize_vpa(cls, value: str) -> str:
        normalized = value.strip().lower()
        if not VPA_PATTERN.fullmatch(normalized):
            raise ValueError("vpa must be a valid UPI virtual payment address")
        return normalized


class TrustLookupResponse(StrictModel):
    trust: PayeeTrust


class RiskScoreRequest(StrictModel):
    payment: PaymentDetails
    device_id: DeviceId
    context: ContextSignals | None = None
    context_token: ContextToken | None = None
    environment: EnvironmentSignals | None = None
    qr_provenance: QrProvenance | None = None

    @field_validator("device_id")
    @classmethod
    def validate_device_id(cls, value: str) -> str:
        if not DEVICE_ID_PATTERN.fullmatch(value):
            raise ValueError("device_id contains unsupported characters")
        return value


class RiskExplainRequest(StrictModel):
    assessment_id: AssessmentId
    consent_to_external_ai: StrictBool = False


class RiskExplainResponse(StrictModel):
    available: bool
    source: Literal["gemini", "template"]
    status: Literal[
        "generated",
        "ai_disabled",
        "consent_required",
        "provider_unavailable",
        "malformed_response",
    ]
    explanation: str = Field(min_length=1, max_length=400)


class RiskAssessmentPayload(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)

    assessment_id: AssessmentId | None = None
    score: int = Field(ge=0, le=100)
    level: RiskLevel
    signals: list[RiskSignal] = Field(max_length=32)
    recommended_action: str = Field(min_length=1, max_length=500)

    @field_validator("level", mode="before")
    @classmethod
    def normalize_level(cls, value: object) -> object:
        if isinstance(value, str) and value.strip().upper().replace("_", " ") == "HIGH RISK":
            return RiskLevel.HIGH
        return value


class RiskScoreResponse(RiskAssessmentPayload):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    assessment_id: str
    transaction_id: str
    payment: PaymentDetails
    payee_trust: PayeeTrust
    requires_confirmation: bool
    handoff_policy: Literal["NORMAL", "DELIBERATE_CONFIRMATION", "PAUSED"]
    assessed_at: datetime


class ResponsePrepareRequest(StrictModel):
    payment: PaymentDetails
    assessment: RiskAssessmentPayload
    context: ContextSignals | None = None
    suspicious_message: str | None = Field(default=None, max_length=2_000)
    already_paid: StrictBool = False

    @field_validator("suspicious_message")
    @classmethod
    def normalize_message(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        return value or None


class PreparedAction(StrictModel):
    code: str
    label: str
    description: str
    requires_confirmation: bool
    external_target: str | None = None
    share_text: str | None = None


class IncidentReport(StrictModel):
    generated_at: datetime
    status: Literal["PRE_PAYMENT", "ALREADY_PAID"]
    recipient_vpa: str
    recipient_name: str | None
    amount: Decimal | None
    currency: str
    transaction_reference: str | None
    transaction_note: str | None
    suspicious_message: str | None
    context_signals: ContextSignals | None
    risk_score: int
    risk_level: RiskLevel
    detected_signals: list[RiskSignal]
    summary: str
    data_provenance: str

    @field_serializer("amount", when_used="json")
    def serialize_amount(self, value: Decimal | None) -> float | None:
        return float(value) if value is not None else None


class PreparedResponse(StrictModel):
    mode: Literal["PREVENTION", "RECOVERY"]
    summary: str
    report: IncidentReport
    actions: list[PreparedAction]
    official_reporting_url: str
    official_helpline: str
    external_actions_performed: bool = False
    disclaimer: str


class HistoryItem(StrictModel):
    assessment_id: str
    transaction_id: str
    assessed_at: datetime
    payment: PaymentDetails
    score: int
    level: RiskLevel
    signals: list[RiskSignal]
    recommended_action: str


class HistoryResponse(StrictModel):
    items: list[HistoryItem]
    count: int


class DemoScenario(StrictModel):
    id: str = Field(pattern=r"^[a-z0-9-]+$")
    title: str
    description: str
    upi_uri: str
    device_id: DeviceId
    context: ContextSignals | None = None
    context_token: ContextToken | None = None
    expected_level: RiskLevel
    expected_score: int = Field(ge=0, le=100)


class DemoScenariosResponse(StrictModel):
    scenarios: list[DemoScenario]


class HealthResponse(StrictModel):
    status: Literal["ok", "degraded"]
    service: str
    version: str
    database: Literal["ok", "unavailable"]
    optional_ai: Literal["configured", "disabled"]
