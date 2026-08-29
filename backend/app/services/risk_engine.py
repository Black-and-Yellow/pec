from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import Decimal
from typing import Any

from app.db.models import FraudIndicator
from app.risk_policy import THRESHOLDS, WEIGHTS, RiskThresholds, RiskWeights
from app.schemas import (
    ACTIVE_CALL_STATES,
    CallActivity,
    ContextSignals,
    EnvironmentSignals,
    PayeeTrust,
    PaymentDetails,
    RemoteAccessTool,
    RiskAssessmentPayload,
    RiskLevel,
    RiskSignal,
    TrustGrade,
)

REMOTE_ACCESS_TOOL_LABELS: dict[RemoteAccessTool, str] = {
    RemoteAccessTool.ANYDESK: "AnyDesk",
    RemoteAccessTool.TEAMVIEWER: "TeamViewer",
    RemoteAccessTool.RUSTDESK: "RustDesk",
    RemoteAccessTool.AIRDROID: "AirDroid",
    RemoteAccessTool.OTHER: "a remote-access tool",
}

CALL_ACTIVITY_LABELS: dict[CallActivity, str] = {
    CallActivity.CELLULAR: "a phone call",
    CallActivity.VOICE_OVER_IP: "an internet call, such as WhatsApp",
    CallActivity.UNKNOWN: "a call",
    CallActivity.RINGING: "an incoming call",
    CallActivity.NONE: "no call",
}

SUSPICIOUS_NOTE_PATTERN = re.compile(
    r"\b(urgent|immediately|kyc|verify now|account (?:block|freeze|suspend)|"
    r"refund fee|reward|prize|customer care)\b",
    re.IGNORECASE,
)

CORROBORATING_SIGNAL_CODES = frozenset(
    {
        "SEEDED_FRAUD_MATCH",
        "REMOTE_ACCESS_TOOL_PRESENT",
        "ACTIVE_CALL_DURING_CHECK",
        "SCREEN_SHARE_DURING_CALL",
        "PAYEE_IDENTITY_IMPERSONATION",
        "SUSPICIOUS_PAYMENT_NOTE",
        "SEEDED_IDENTIFIER_RELATIONSHIP",
        "CONTEXT_IMPERSONATION",
        "CONTEXT_URGENCY",
        "CONTEXT_KYC_THREAT",
        "CONTEXT_REWARD_OR_REFUND",
        "CONTEXT_SUSPICIOUS_SUPPORT",
    }
)


@dataclass(frozen=True, slots=True)
class RiskInputs:
    payment: PaymentDetails
    known_payee: bool
    typical_amount: Decimal | None
    indicator: FraudIndicator | None
    context: ContextSignals | None = None
    environment: EnvironmentSignals | None = None
    payee_trust: PayeeTrust | None = None


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

        remote_tools = list(inputs.environment.remote_access_tools) if inputs.environment else []
        call_activity = (
            inputs.environment.call_activity if inputs.environment else CallActivity.NONE
        )
        on_active_call = call_activity in ACTIVE_CALL_STATES

        if remote_tools:
            signals.append(
                RiskSignal(
                    code="REMOTE_ACCESS_TOOL_PRESENT",
                    label="A remote-access app is installed on this device",
                    weight=self._weights.remote_access_tool,
                    evidence=(
                        f"{self._describe_remote_tools(remote_tools)} can let someone else see "
                        "and control this screen. Scammers ask victims to install these before "
                        "a payment."
                    ),
                )
            )

        if on_active_call:
            signals.append(
                RiskSignal(
                    code="ACTIVE_CALL_DURING_CHECK",
                    label="You are on a call while making this payment",
                    weight=self._weights.active_call,
                    evidence=(
                        f"FinGuard saw {CALL_ACTIVITY_LABELS[call_activity]} in progress when "
                        "this check started. Almost every large UPI fraud is talked through "
                        "live, because a caller can override hesitation that a message cannot."
                    ),
                )
            )
        elif call_activity is CallActivity.RINGING:
            signals.append(
                RiskSignal(
                    code="INCOMING_CALL_DURING_CHECK",
                    label="A call is ringing while you pay",
                    weight=self._weights.incoming_call_ringing,
                    evidence=(
                        "An incoming call was ringing when this check started. Do not let a "
                        "caller walk you through a payment."
                    ),
                )
            )

        if on_active_call and remote_tools:
            signals.append(
                RiskSignal(
                    code="SCREEN_SHARE_DURING_CALL",
                    label="Someone can watch this screen while talking to you",
                    weight=self._weights.call_with_remote_access,
                    evidence=(
                        "A remote-access app and a live call at the same time is the exact "
                        "setup used for digital-arrest and fake-support frauds. Hang up and "
                        "uninstall the app before paying anyone."
                    ),
                )
            )

        trust = inputs.payee_trust
        if trust is not None:
            signals.extend(
                self._trust_signals(trust, seeded_match=inputs.indicator is not None)
            )

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

        amount_signal_index = len(signals)

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

        if payment.amount is None:
            corroborated = any(
                signal.code in CORROBORATING_SIGNAL_CODES for signal in signals
            )
            weight = (
                self._weights.amount_not_specified_corroborated
                if corroborated
                else self._weights.amount_not_specified
            )
            evidence = (
                "The amount is unspecified and other warning signals already fired, so an "
                "open-ended request is treated as higher risk."
                if corroborated
                else "The amount will be entered in your UPI app. This is normal for a static "
                "merchant QR, so FinGuard weights it lightly on its own."
            )
            signals.insert(
                amount_signal_index,
                RiskSignal(
                    code="AMOUNT_NOT_SPECIFIED",
                    label="Payment amount is not specified",
                    weight=weight,
                    evidence=evidence,
                ),
            )

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
    def _describe_remote_tools(tools: list[RemoteAccessTool]) -> str:
        names = list(dict.fromkeys(REMOTE_ACCESS_TOOL_LABELS[tool] for tool in tools))
        if len(names) == 1:
            return names[0]
        return f"{', '.join(names[:-1])} and {names[-1]}"

    @staticmethod
    def _relationship_count(indicator: FraudIndicator) -> int:
        relationships: dict[str, Any] = indicator.relationships or {}
        return sum(len(value) for value in relationships.values() if isinstance(value, list))

    def _has_relationship_evidence(self, indicator: FraudIndicator) -> bool:
        return indicator.report_count > 1 or self._relationship_count(indicator) > 0

    def _trust_signals(
        self, trust: PayeeTrust, *, seeded_match: bool
    ) -> list[RiskSignal]:
        """Turn the payee reputation report into scoring signals.

        A thin file deliberately adds nothing: FIRST_TIME_PAYEE already says
        the payer has no history with this recipient, and charging a genuine
        new shop twice for the same fact would make the score unreadable.
        """
        signals: list[RiskSignal] = []
        if trust.impersonation:
            signals.append(
                RiskSignal(
                    code="PAYEE_IDENTITY_IMPERSONATION",
                    label="The recipient address imitates an organisation",
                    weight=self._weights.payee_identity_impersonation,
                    evidence=trust.headline
                    + ". Read the address itself, not the name shown beside it.",
                )
            )
        elif (
            not trust.thin_file
            and not seeded_match
            and trust.grade in {TrustGrade.C, TrustGrade.D}
        ):
            signals.append(
                RiskSignal(
                    code="PAYEE_TRUST_LOW",
                    label="This recipient has a weak record on the FinGuard network",
                    weight=self._weights.payee_trust_low,
                    evidence=(
                        f"Payee trust grade {trust.grade.value} ({trust.score or 0}/100) "
                        f"across {trust.check_count} checks from "
                        f"{trust.distinct_device_count} devices."
                    ),
                )
            )
        return signals

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
