from __future__ import annotations

from datetime import UTC, datetime

from app.schemas import (
    ContextSignals,
    IncidentReport,
    PaymentDetails,
    PreparedAction,
    PreparedResponse,
    RiskAssessmentPayload,
    RiskLevel,
)
from app.services.payment_handoff import build_upi_handoff_uri

OFFICIAL_REPORTING_URL = "https://cybercrime.gov.in/"
OFFICIAL_HELPLINE = "1930"


def _format_amount(payment: PaymentDetails) -> str:
    if payment.amount is None:
        return "an amount not specified in the request"
    return f"INR {payment.amount:,.2f}"


def _risk_label(level: RiskLevel) -> str:
    return "HIGH RISK" if level is RiskLevel.HIGH else level.value


def _incident_summary(
    payment: PaymentDetails, assessment: RiskAssessmentPayload, *, already_paid: bool
) -> str:
    timing = "reported as already paid" if already_paid else "checked before UPI handoff"
    summary = (
        f"A payment to {payment.vpa} for {_format_amount(payment)} was {timing}. "
        f"FinGuard's deterministic assessment was {_risk_label(assessment.level)} "
        f"({assessment.score}/100) based on {len(assessment.signals)} explainable signal(s)."
    )
    if payment.transaction_note:
        summary += f" The payment request note was: {payment.transaction_note}."
    return summary


def _share_message(payment: PaymentDetails, assessment: RiskAssessmentPayload) -> str:
    return (
        f"I stopped to check a UPI payment to {payment.vpa}. FinGuard rated it "
        f"{_risk_label(assessment.level)} ({assessment.score}/100) from explainable local signals. "
        "Please contact me before I continue."
    )


def _prevention_actions(
    payment: PaymentDetails, assessment: RiskAssessmentPayload
) -> list[PreparedAction]:
    handoff_uri = build_upi_handoff_uri(payment)
    stop = PreparedAction(
        code="STOP_HERE",
        label="Stop here",
        description="End this check without opening a payment app.",
        requires_confirmation=False,
    )
    if assessment.level is RiskLevel.SAFE:
        return [
            PreparedAction(
                code="OPEN_UPI_APP",
                label="Continue to UPI app",
                description=(
                    "Open the validated payment request in a normal UPI app. "
                    "FinGuard does not execute the payment."
                ),
                requires_confirmation=True,
                external_target=handoff_uri,
            ),
            stop,
        ]

    actions = [
        stop,
        PreparedAction(
            code="CHECK_RECIPIENT",
            label="Check recipient",
            description="Verify the recipient using a phone number or channel you already trust.",
            requires_confirmation=False,
        ),
    ]
    if assessment.level is RiskLevel.HIGH:
        actions.extend(
            [
                PreparedAction(
                    code="PREPARE_REPORT",
                    label="Prepare report",
                    description=(
                        "Review and copy the incident draft. Nothing is submitted automatically."
                    ),
                    requires_confirmation=False,
                ),
                PreparedAction(
                    code="ALERT_TRUSTED_CONTACT",
                    label="Alert trusted contact",
                    description="Open the device share sheet with a prepared message.",
                    requires_confirmation=True,
                    share_text=_share_message(payment, assessment),
                ),
            ]
        )
    actions.append(
        PreparedAction(
            code="CONTINUE_ANYWAY",
            label="Continue anyway",
            description=(
                "After an explicit warning confirmation, open the request in a normal UPI app. "
                "FinGuard still does not execute the payment."
            ),
            requires_confirmation=True,
            external_target=handoff_uri,
        )
    )
    return actions


def _recovery_actions(
    payment: PaymentDetails, assessment: RiskAssessmentPayload
) -> list[PreparedAction]:
    return [
        PreparedAction(
            code="COPY_REPORT",
            label="Copy incident report",
            description="Copy the prepared facts so you can review them before reporting.",
            requires_confirmation=True,
        ),
        PreparedAction(
            code="OPEN_OFFICIAL_REPORTING",
            label="Open official reporting portal",
            description=(
                "Open India's official cybercrime reporting website. No report is auto-submitted."
            ),
            requires_confirmation=True,
            external_target=OFFICIAL_REPORTING_URL,
        ),
        PreparedAction(
            code="CALL_1930",
            label="Call 1930",
            description="Open the phone dialer for India's cyber-fraud helpline.",
            requires_confirmation=True,
            external_target=f"tel:{OFFICIAL_HELPLINE}",
        ),
        PreparedAction(
            code="ALERT_TRUSTED_CONTACT",
            label="Alert trusted contact",
            description="Open the device share sheet with a prepared message.",
            requires_confirmation=True,
            share_text=_share_message(payment, assessment),
        ),
    ]


def build_prepared_response(
    *,
    payment: PaymentDetails,
    assessment: RiskAssessmentPayload,
    context: ContextSignals | None,
    suspicious_message: str | None,
    already_paid: bool,
) -> PreparedResponse:
    summary = _incident_summary(payment, assessment, already_paid=already_paid)
    report = IncidentReport(
        generated_at=datetime.now(UTC),
        status="ALREADY_PAID" if already_paid else "PRE_PAYMENT",
        recipient_vpa=payment.vpa,
        recipient_name=payment.payee_name,
        amount=payment.amount,
        currency=payment.currency,
        transaction_reference=payment.transaction_reference,
        transaction_note=payment.transaction_note,
        suspicious_message=suspicious_message,
        context_signals=context,
        risk_score=assessment.score,
        risk_level=assessment.level,
        detected_signals=assessment.signals,
        summary=summary,
        data_provenance=(
            "Drafted from user-supplied payment/context, local device history where available, "
            "and clearly labelled seeded indicators. FinGuard has no NPCI or bank-internal "
            "data access."
        ),
    )
    return PreparedResponse(
        mode="RECOVERY" if already_paid else "PREVENTION",
        summary=summary,
        report=report,
        actions=(
            _recovery_actions(payment, assessment)
            if already_paid
            else _prevention_actions(payment, assessment)
        ),
        official_reporting_url=OFFICIAL_REPORTING_URL,
        official_helpline=OFFICIAL_HELPLINE,
        external_actions_performed=False,
        disclaimer=(
            "FinGuard evaluates a request before handoff; it cannot freeze, reverse, cancel, "
            "or intercept a bank transaction. Verify every draft before using an external action."
        ),
    )
