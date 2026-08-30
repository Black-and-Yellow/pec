"""Compare what the user believes is about to happen with what the request does.

Almost every refund, reward, cashback and "KYC verification" scam works the
same way: the victim is told money is coming *to* them, and is then walked
through an action that sends money *away*. The UPI request itself is often
unremarkable - a plain ``upi://pay`` to an address with no history, which is
also what a legitimate first payment to a new shop looks like. The scoring
engine cannot separate those two, because on the evidence it can see they are
the same request.

What separates them is the belief the person is holding. Somebody who says "I
was promised a refund" and is looking at a request that will debit them has
already been told something false, and that is checkable without any model.

Two rules keep this honest and keep it out of the score:

Intent never touches the risk score. A mismatch says the *user* was misled,
not that the payee is a fraudster - a genuine shop's QR produces this warning
if the payer mistakenly believes they are collecting. Letting a self-reported
belief move a payee's verdict would let anyone brand an address by lying to a
dropdown.

The verdict is deterministic and needs no AI. It is a comparison between an
enumerated choice and the parsed direction of the request.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class PaymentIntent(StrEnum):
    """What the user believes this request is for, in their own words."""

    SEND_MONEY = "SEND_MONEY"
    RECEIVE_MONEY = "RECEIVE_MONEY"
    REFUND_OR_REWARD = "REFUND_OR_REWARD"
    VERIFY_KYC_OR_ACCOUNT = "VERIFY_KYC_OR_ACCOUNT"
    INSPECT_ONLY = "INSPECT_ONLY"


#: Beliefs that are incompatible with a request that debits the user. Each is a
#: documented pretext: money arriving, money coming back, or an account check.
INBOUND_EXPECTATIONS: frozenset[PaymentIntent] = frozenset(
    {
        PaymentIntent.RECEIVE_MONEY,
        PaymentIntent.REFUND_OR_REWARD,
        PaymentIntent.VERIFY_KYC_OR_ACCOUNT,
    }
)

HEADLINE = "STOP - this request sends money."

EXPECTATION_DETAIL: dict[PaymentIntent, str] = {
    PaymentIntent.RECEIVE_MONEY: (
        "You said you expect to receive money. This request pays money out of "
        "your account instead."
    ),
    PaymentIntent.REFUND_OR_REWARD: (
        "You said you were promised a refund or reward. A genuine refund "
        "arrives on its own. It never requires you to approve a payment."
    ),
    PaymentIntent.VERIFY_KYC_OR_ACCOUNT: (
        "You said this is to verify KYC or account access. No bank, wallet or "
        "government service verifies you by taking a payment."
    ),
}

RULE = (
    "Scanning a QR or entering a UPI PIN is never required to receive money. "
    "A PIN only ever authorises money leaving your account."
)


@dataclass(frozen=True, slots=True)
class IntentAssessment:
    """Whether the stated expectation matches what the request actually does."""

    intent: PaymentIntent
    #: True when the user expects money in and the request pays money out.
    mismatched: bool
    headline: str | None
    detail: str | None
    rule: str | None

    @property
    def should_warn(self) -> bool:
        return self.mismatched


def assess(intent: PaymentIntent | None, *, request_sends_money: bool) -> IntentAssessment:
    """Compare a stated expectation against the direction of the request.

    ``request_sends_money`` is the parsed fact, not a guess: a ``upi://pay``
    request debits whoever approves it.
    """
    if intent is None:
        return IntentAssessment(
            intent=PaymentIntent.INSPECT_ONLY,
            mismatched=False,
            headline=None,
            detail=None,
            rule=None,
        )
    mismatched = request_sends_money and intent in INBOUND_EXPECTATIONS
    if not mismatched:
        return IntentAssessment(
            intent=intent,
            mismatched=False,
            headline=None,
            detail=None,
            rule=None,
        )
    return IntentAssessment(
        intent=intent,
        mismatched=True,
        headline=HEADLINE,
        detail=EXPECTATION_DETAIL[intent],
        rule=RULE,
    )
