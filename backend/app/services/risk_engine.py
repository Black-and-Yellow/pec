from __future__ import annotations

import re
from dataclasses import dataclass
from decimal import ROUND_CEILING, Decimal
from typing import Any

from app.db.models import FraudIndicator
from app.repositories.reputation_repository import ReputationSnapshot
from app.risk_policy import THRESHOLDS, WEIGHTS, RiskThresholds, RiskWeights
from app.schemas import (
    ACTIVE_CALL_STATES,
    CallActivity,
    ContextSignals,
    EnvironmentSignals,
    PayeeTrust,
    PaymentDetails,
    QrProvenance,
    RemoteAccessTool,
    RiskAssessmentPayload,
    RiskLevel,
    RiskSignal,
    TrustGrade,
)
from app.services import mule_signature
from app.services.vpa_identity import analyze_vpa, borrowed_brand_in_claimed_name

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

# These are ordering steps, not policy weights. The policy-supplied ceiling
# controls the maximum score contribution and is the sole authority for it.
TRUST_GRADE_SEVERITY: dict[TrustGrade, int] = {
    TrustGrade.A_PLUS: 0,
    TrustGrade.A: 1,
    TrustGrade.B: 2,
    TrustGrade.C: 3,
    TrustGrade.NEW: 4,
    TrustGrade.D: 5,
}
MAXIMUM_TRUST_GRADE_SEVERITY = max(TRUST_GRADE_SEVERITY.values())
AMOUNT_SCALE_SATURATION_MULTIPLIER = Decimal("5")


@dataclass(frozen=True, slots=True)
class RiskInputs:
    payment: PaymentDetails
    known_payee: bool
    typical_amount: Decimal | None
    indicator: FraudIndicator | None
    context: ContextSignals | None = None
    qr_provenance: QrProvenance | None = None
    environment: EnvironmentSignals | None = None
    payee_trust: PayeeTrust | None = None
    reputation: ReputationSnapshot | None = None


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
            signals.extend(self._trust_signals(trust, seeded_match=inputs.indicator is not None))

        # What the address itself discloses, scored whether or not the network
        # has ever seen it. The trust grade cannot carry this on a thin file:
        # with no ledger the score normalises over identity alone, so a pretext
        # address reads as a high percentage and grades well. Without these
        # signals 'kyc-verify-now@ybl' scored exactly the same as a legitimate
        # tailor nobody had checked either.
        signals.extend(self._address_signals(payment.vpa))

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

        # Read the ledger for the collection-account shape. This is the one
        # signal that can see a mule: the address itself is structurally
        # innocent, so only the traffic through it gives the pattern away.
        mule = mule_signature.assess(inputs.reputation)
        if mule.matched:
            signals.append(
                RiskSignal(
                    code="MULE_ACCOUNT_SIGNATURE",
                    label="This address is collecting like a money-mule account",
                    weight=self._weights.mule_account_signature,
                    evidence=mule.evidence,
                )
            )

        if payment.payee_name is not None:
            borrowed_brand = borrowed_brand_in_claimed_name(
                payment.payee_name,
                payment.vpa,
            )
            weight = (
                self._weights.payee_name_unverified_borrowed_brand
                if borrowed_brand is not None
                else self._weights.payee_name_unverified_informational
            )
            # Since 1 June 2026 every UPI app must display the bank-verified
            # payee name before confirmation, so the comparison this evidence
            # asks for is one the payer is guaranteed to be able to make on the
            # very next screen. That turns a limitation FinGuard cannot fix
            # into a specific, checkable instruction.
            evidence = (
                f"The claimed payee name uses '{borrowed_brand}', but the VPA handle does not "
                "back that organisation. Your UPI app must show the bank-verified name before "
                "you authorise: if it is not this organisation, stop."
                if borrowed_brand is not None
                else "The payee name comes from the payment request and cannot be verified "
                "from the VPA alone. Compare it against the bank-verified name your UPI app "
                "is required to show on the confirmation screen."
            )
            signals.append(
                RiskSignal(
                    code="PAYEE_NAME_UNVERIFIED",
                    label="The claimed payee name is not independently verified",
                    weight=weight,
                    evidence=evidence,
                )
            )
        amount_signal_index = len(signals)

        unusual_threshold = self._unusual_amount_threshold(inputs.typical_amount)
        if (
            not inputs.known_payee
            and payment.amount is not None
            and payment.amount >= unusual_threshold
        ):
            if trust is None:
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
            else:
                weight = self._trust_scaled_amount_weight(
                    amount=payment.amount,
                    unusual_threshold=unusual_threshold,
                    grade=trust.grade,
                )
                signals.append(
                    RiskSignal(
                        code="AMOUNT_SCALED_BY_TRUST",
                        label="Amount risk is scaled by the recipient's network record",
                        weight=weight,
                        evidence=(
                            f"INR {payment.amount:.2f} is high for a new recipient; payee "
                            f"trust grade {trust.grade.value} scales this contribution."
                        ),
                    )
                )

        if self._has_missing_qr_provenance(payment, inputs.qr_provenance):
            signals.append(
                RiskSignal(
                    code="QR_PROVENANCE_MISSING",
                    label="Merchant-shaped QR does not include provenance fields",
                    weight=self._weights.qr_provenance_missing,
                    evidence=(
                        "The supplied QR describes a priced merchant payment but does not "
                        "include a sign or organisation identifier. FinGuard only checks "
                        "field presence; it cannot validate NPCI signatures."
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
            corroborated = any(signal.code in CORROBORATING_SIGNAL_CODES for signal in signals)
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

    def _trust_scaled_amount_weight(
        self,
        *,
        amount: Decimal,
        unusual_threshold: Decimal,
        grade: TrustGrade,
    ) -> int:
        """Scale an unusual amount within the named policy ceiling."""
        ceiling = self._weights.amount_scaled_by_trust
        severity = TRUST_GRADE_SEVERITY[grade]
        if severity == 0:
            return 0
        amount_scale = min(
            Decimal(1),
            amount / (unusual_threshold * AMOUNT_SCALE_SATURATION_MULTIPLIER),
        )
        shared_amount_weight = int(
            (Decimal(ceiling - MAXIMUM_TRUST_GRADE_SEVERITY) * amount_scale).to_integral_value(
                rounding=ROUND_CEILING
            )
        )
        return min(ceiling, shared_amount_weight + severity)

    @staticmethod
    def _has_missing_qr_provenance(
        payment: PaymentDetails,
        provenance: QrProvenance | None,
    ) -> bool:
        """Accept provenance only as a risk-raising client observation."""
        return (
            provenance is not None
            and payment.amount is not None
            and payment.transaction_reference is not None
            and not provenance.sign_present
            and not provenance.orgid_present
        )

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

    def _address_signals(self, vpa: str) -> list[RiskSignal]:
        """Score the structural concerns the address raises about itself.

        Impersonation is not repeated here: a borrowed brand or a lookalike
        handle already reaches the score through PAYEE_IDENTITY_IMPERSONATION,
        and charging twice for one fact would make the breakdown unreadable.
        """
        identity = analyze_vpa(vpa)
        concerns = {finding.code: finding for finding in identity.findings if finding.points == 0}
        definitions = (
            (
                "PRETEXT_IN_ADDRESS",
                "PAYEE_ADDRESS_PRETEXT",
                "The address names a reason to pay rather than a payee",
                self._weights.payee_address_pretext,
            ),
            (
                "PHONE_DERIVED_ADDRESS",
                "PAYEE_ADDRESS_DISPOSABLE",
                "The address is a phone number rather than a name",
                self._weights.payee_address_disposable,
            ),
            (
                "UNRECOGNIZED_HANDLE",
                "PAYEE_HANDLE_UNRECOGNIZED",
                "No known payment provider issues this handle",
                self._weights.payee_handle_unrecognized,
            ),
        )
        return [
            RiskSignal(
                code=code,
                label=label,
                weight=weight,
                evidence=concerns[finding_code].evidence[:300],
            )
            for finding_code, code, label, weight in definitions
            if finding_code in concerns
        ]

    def _trust_signals(self, trust: PayeeTrust, *, seeded_match: bool) -> list[RiskSignal]:
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
            not trust.thin_file and not seeded_match and trust.grade in {TrustGrade.C, TrustGrade.D}
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
