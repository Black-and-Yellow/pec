from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from app.db.models import FraudIndicator
from app.risk_policy import THRESHOLDS, WEIGHTS, RiskThresholds, RiskWeights
from app.schemas import (
    ContextSignals,
    PaymentDetails,
    RiskAssessmentPayload,
    RiskLevel,
    RiskSignal,
)

SUSPICIOUS_NOTE_PATTERN = re.compile(
    r"\b(urgent|immediately|kyc|verify now|account (?:block|freeze|suspend)|"
    r"refund fee|reward|prize|customer care)\b",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class RiskInputs:
    payment: PaymentDetails
    known_payee: bool
    typical_amount: Decimal | None
    indicator: FraudIndicator | None
    context: ContextSignals | None = None


class RiskEngine:
    def __init__(
        self,
        *,
        weights: RiskWeights = WEIGHTS,
        thresholds: RiskThresholds = THRESHOLDS,
    ) -> None:
        self._weights = weights
        self._thresholds = thresholds

    def score(self, inputs: RiskInputs) -> RiskAssessmentPayload:
        signals: list[RiskSignal] = []
        payment = inputs.payment

        if inputs.indicator is not None:
            signals.append(
                RiskSignal(
                    code="SEEDED_FRAUD_MATCH",
                    label="Recipient matches a seeded scam indicator",
                    weight=self._weights.seeded_fraud_match,
                    evidence=(
                        f"VPA matched '{inputs.indicator.label}' in clearly labelled seeded "
                        "demo data"
                    ),
                )
            )

        if not inputs.known_payee:
            signals.append(
                RiskSignal(
                    code="FIRST_TIME_PAYEE",
                    label="This is a first-time recipient on this device",
                    weight=self._weights.first_time_payee,
                    evidence=(
                        "No completed payment to this VPA exists in this device's local history"
                    ),
                )
            )

        if payment.amount is None:
            signals.append(
                RiskSignal(
                    code="AMOUNT_NOT_SPECIFIED",
                    label="Payment amount is not specified",
                    weight=self._weights.amount_not_specified,
                    evidence=(
                        "The amount would be entered after handoff, so FinGuard could not "
                        "evaluate it before opening a UPI app"
                    ),
                )
            )

        unusual_threshold = self._unusual_amount_threshold(inputs.typical_amount)
        if (
            not inputs.known_payee
            and payment.amount is not None
            and payment.amount >= unusual_threshold
        ):
            signals.append(
                RiskSignal(
                    code="UNUSUAL_AMOUNT",
                    label="Amount is unusually high for a new recipient",
                    weight=self._weights.unusual_amount,
                    evidence=(
                        f"INR {payment.amount:.2f} meets the local-history threshold of "
                        f"INR {unusual_threshold:.2f}"
                    ),
                )
            )

        if payment.transaction_note and SUSPICIOUS_NOTE_PATTERN.search(payment.transaction_note):
            signals.append(
                RiskSignal(
                    code="SUSPICIOUS_PAYMENT_NOTE",
                    label="Payment note contains suspicious pressure or pretext language",
                    weight=self._weights.suspicious_note,
                    evidence=(
                        "The supplied payment note contains urgency, KYC, support, or reward "
                        "wording"
                    ),
                )
            )

        if inputs.indicator is not None and self._has_relationship_evidence(inputs.indicator):
            related_count = self._relationship_count(inputs.indicator)
            signals.append(
                RiskSignal(
                    code="SEEDED_IDENTIFIER_RELATIONSHIP",
                    label="Recipient is linked to other seeded suspicious identifiers",
                    weight=self._weights.identifier_relationship,
                    evidence=(
                        f"Seeded demo data links this VPA to {related_count} other identifier(s) "
                        f"and {inputs.indicator.report_count} seeded report(s)"
                    ),
                )
            )

        if (
            inputs.context
            and inputs.context.confidence >= self._thresholds.minimum_context_confidence
        ):
            signals.extend(self._context_signals(inputs.context))

        score = max(0, min(100, sum(signal.weight for signal in signals)))
        level = self._level(score)
        return RiskAssessmentPayload(
            score=score,
            level=level,
            signals=signals,
            recommended_action=self._recommendation(level),
        )

    def _unusual_amount_threshold(self, typical_amount: Decimal | None) -> Decimal:
        if typical_amount is None:
            return Decimal(self._thresholds.no_history_unusual_amount)
        historical_threshold = typical_amount * self._thresholds.amount_multiplier
        return max(Decimal(self._thresholds.minimum_unusual_amount), historical_threshold)

    @staticmethod
    def _relationship_count(indicator: FraudIndicator) -> int:
        relationships: dict[str, Any] = indicator.relationships or {}
        return sum(len(value) for value in relationships.values() if isinstance(value, list))

    def _has_relationship_evidence(self, indicator: FraudIndicator) -> bool:
        return indicator.report_count > 1 or self._relationship_count(indicator) > 0

    def _context_signals(self, context: ContextSignals) -> list[RiskSignal]:
        definitions = (
            (
                context.impersonation,
                "CONTEXT_IMPERSONATION",
                "Message may impersonate a trusted organization",
                self._weights.context_impersonation,
                "User-supplied context analysis flagged impersonation language",
            ),
            (
                context.urgency,
                "CONTEXT_URGENCY",
                "Message applies unusual urgency or pressure",
                self._weights.context_urgency,
                "User-supplied context analysis flagged urgency language",
            ),
            (
                context.kyc_threat,
                "CONTEXT_KYC_THREAT",
                "Message uses a KYC or account-blocking threat",
                self._weights.context_kyc_threat,
                "User-supplied context analysis flagged a KYC-related threat",
            ),
            (
                context.reward_or_refund_claim,
                "CONTEXT_REWARD_OR_REFUND",
                "Message promises a reward or refund",
                self._weights.context_reward_or_refund,
                "User-supplied context analysis flagged reward or refund language",
            ),
            (
                context.suspicious_support_claim,
                "CONTEXT_SUSPICIOUS_SUPPORT",
                "Message makes a suspicious customer-support claim",
                self._weights.context_suspicious_support,
                "User-supplied context analysis flagged an unsolicited support claim",
            ),
        )
        return [
            RiskSignal(code=code, label=label, weight=weight, evidence=evidence)
            for enabled, code, label, weight, evidence in definitions
            if enabled
        ]

    def _level(self, score: int) -> RiskLevel:
        if score <= self._thresholds.safe_max:
            return RiskLevel.SAFE
        if score <= self._thresholds.caution_max:
            return RiskLevel.CAUTION
        return RiskLevel.HIGH

    @staticmethod
    def _recommendation(level: RiskLevel) -> str:
        if level is RiskLevel.SAFE:
            return (
                "Verify the recipient details, then continue in your usual UPI app if they are "
                "correct."
            )
        if level is RiskLevel.CAUTION:
            return (
                "Check the recipient independently and review the amount before deliberately "
                "continuing."
            )
        return (
            "Stop the UPI handoff and verify the recipient independently. "
            "Prepare recovery actions if you already paid."
        )
