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
        if value is not None and value.as_tuple().exponent < -2:
            raise ValueError("amount must have at most two decimal places")
        return value

    @field_validator("payee_name", "transaction_note", "transaction_reference")
    @classmethod
    def reject_control_characters(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = " ".join(value.split())
        if any(ord(character) < 32 for character in cleaned):
            raise ValueError("control characters are not allowed")
        return cleaned or None

    @field_serializer("amount", when_used="json")
    def serialize_amount(self, value: Decimal | None) -> float | None:
        return float(value) if value is not None else None


class ParsePaymentRequest(StrictModel):
    upi_uri: str = Field(min_length=1, max_length=2_048)


class ParsePaymentResponse(StrictModel):
    payment: PaymentDetails
    canonical_uri: str


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


class RiskSignal(StrictModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_]+$", max_length=64)
    label: str = Field(min_length=1, max_length=160)
    weight: int = Field(ge=0, le=100)
    evidence: str = Field(min_length=1, max_length=300)


class RiskScoreRequest(StrictModel):
    payment: PaymentDetails
    device_id: DeviceId = "demo-device"
    context: ContextSignals | None = None

    @field_validator("device_id")
    @classmethod
    def validate_device_id(cls, value: str) -> str:
        if not DEVICE_ID_PATTERN.fullmatch(value):
            raise ValueError("device_id contains unsupported characters")
        return value


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
