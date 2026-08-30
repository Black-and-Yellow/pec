"""A published, versioned account of how FinGuard scores a payment request.

The scoring policy is the part of this app a judge is most entitled to be
sceptical about. Numbers on a screen look like measurements, and these are
not: they are intervention values chosen by hand so that the combinations
that matter cross a threshold at the right moment. Nothing here was fitted to
a labelled dataset.

Where a published advisory from NPCI, RBI or I4C warns about the behaviour a
signal looks for, that source is named. Where it does not - because the
signal is a heuristic of FinGuard's own, or because the advisory describes
the behaviour without supporting how this app weighs it - the source is
FINGUARD_POLICY, and saying so is the point. No source is cited for any point
value, because none supports one.

Saying that plainly is worth more than an invented accuracy figure, so the
card states it in its own text and the API serves it to the app rather than
letting the client keep a second copy of the weights.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from app.risk_policy import WEIGHTS, RiskThresholds, RiskWeights

POLICY_VERSION = "2026.08-1"

CALIBRATION_STATEMENT = (
    "Official guidance supports the risk factor, not the exact numeric points. "
    "FinGuard's points are deterministic intervention values and are not "
    "statistically calibrated fraud probabilities."
)

LIMITATIONS: tuple[str, ...] = (
    "FinGuard sees a payment request and this device. It cannot see your bank "
    "account, the recipient's account, or any transaction.",
    "Reputation counts safety checks run by FinGuard users, not payments. An "
    "address with no record is unknown here, not proven safe.",
    "The device identifier a check is attributed to is supplied by the client "
    "and can be manipulated, so reach, tenure and velocity can be inflated by "
    "anyone willing to do so. They are not authenticated payer intelligence, "
    "and community standing may raise concern but is never allowed to reduce "
    "a signal below its baseline.",
    "Seeded demo rows exist to make the demo legible and are labelled as such. "
    "They are not observations of real activity.",
    "Scores are not probabilities. A score of 60 does not mean a 60% chance of "
    "fraud; it means enough intervention weight accumulated to warrant a pause.",
)


class SourceCategory(StrEnum):
    """Where the *direction* of a signal is supported, never its point value."""

    NPCI_ADVISORY = "NPCI_ADVISORY"
    RBI_ADVISORY = "RBI_ADVISORY"
    I4C_ADVISORY = "I4C_ADVISORY"
    FINGUARD_POLICY = "FINGUARD_POLICY"


SOURCE_LINKS: dict[SourceCategory, str] = {
    SourceCategory.NPCI_ADVISORY: "https://www.npci.org.in/fraud-awareness",
    SourceCategory.RBI_ADVISORY: (
        "https://systemhealth.rbi.org.in/cms.rbi.org.in/cms/assets/Documents/"
        "BEAWARE07032022.pdf"
    ),
    SourceCategory.I4C_ADVISORY: "https://www.cybercrime.gov.in/",
    SourceCategory.FINGUARD_POLICY: "",
}


@dataclass(frozen=True, slots=True)
class SignalRationale:
    """Why one weight exists, in words a non-engineer can check."""

    title: str
    rationale: str
    source: SourceCategory


# Every field of RiskWeights must appear here exactly once. A weight with no
# published reason is a number nobody can defend, and the test suite fails
# rather than letting one ship.
SIGNAL_RATIONALES: dict[str, SignalRationale] = {
    "seeded_fraud_match": SignalRationale(
        title="Address is on the seeded scam list",
        rationale=(
            "The address matches FinGuard's clearly labelled demo indicator set. "
            "Weighted highest because it is a direct match rather than an inference."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "remote_access_tool": SignalRationale(
        title="A remote-access app is installed",
        rationale=(
            "Screen-sharing tools let another person watch and guide the "
            "payment. Official advisories warn against installing one at a "
            "caller's request."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "active_call": SignalRationale(
        title="A call is in progress during the check",
        rationale=(
            "Official advisories warn that scammers may call while a payment "
            "is being made, because a live caller can push past hesitation."
        ),
        source=SourceCategory.RBI_ADVISORY,
    ),
    "incoming_call_ringing": SignalRationale(
        title="A call is ringing during the check",
        rationale=(
            "Weaker than an answered call: nobody is speaking yet, so it is a "
            "prompt to wait rather than evidence of coaching."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "call_with_remote_access": SignalRationale(
        title="A live call plus screen sharing",
        rationale=(
            "Added on top of both parts. Advisories describe this pairing in "
            "impersonation scams; treating it as worse than either alone is "
            "FinGuard's own judgement."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "payee_identity_impersonation": SignalRationale(
        title="The address borrows a bank or agency name",
        rationale=(
            "A consumer handle carrying a bank, regulator or police name may "
            "be imitating that institution. Verify independently, through a "
            "channel you already trust."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "payee_address_pretext": SignalRationale(
        title="The address names a reason to pay",
        rationale=(
            "Words such as kyc, refund or verify describe a reason to pay "
            "rather than a person or a shop. Treated as a prompt to verify."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "payee_address_disposable": SignalRationale(
        title="The address is a bare phone number",
        rationale=(
            "Phone-derived addresses are cheap to create and abandon. Common for "
            "honest individuals too, so it is weighted as a nudge, not a verdict."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "payee_handle_unrecognized": SignalRationale(
        title="No known provider issues this handle",
        rationale=(
            "The handle is absent from FinGuard's registry of live UPI handles. "
            "Kept low because the registry is deliberately incomplete."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "payee_trust_low": SignalRationale(
        title="Weak record on the FinGuard network",
        rationale=(
            "An address other FinGuard users have checked with poor outcomes. "
            "Kept modest because it is this network's own view, not bank data."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "mule_account_signature": SignalRationale(
        title="Checked like a circulated scam address",
        rationale=(
            "Many unrelated people looked this address up once each, in a "
            "short window, with no history behind it. FinGuard check-pattern "
            "evidence only, not transaction data."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "payee_name_unverified_informational": SignalRationale(
        title="The claimed name cannot be checked here",
        rationale=(
            "Carries no points. Every UPI app must show the bank-verified name "
            "before you authorise, so this is an instruction, not a risk factor."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "payee_name_unverified_borrowed_brand": SignalRationale(
        title="The claimed name borrows an organisation",
        rationale=(
            "The name on the request carries a bank or agency the handle does "
            "not back. Scored because that name is chosen by whoever made the "
            "request, not by a bank."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "first_time_payee": SignalRationale(
        title="First payment to this address from this device",
        rationale=(
            "First payments lack device-local history: there is no record of "
            "paying this address before. Every genuine new payee looks the "
            "same, so this never decides a verdict alone."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "amount_not_specified": SignalRationale(
        title="The request sets no amount",
        rationale=(
            "Normal for a shop's static QR, so it is near-zero on its own and "
            "only matters beside other signals."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "amount_not_specified_corroborated": SignalRationale(
        title="No amount, alongside other warnings",
        rationale=(
            "An open-ended amount is ordinary alone, but lets a caller name "
            "the figure. Combining it with other warnings is FinGuard policy."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "unusual_amount": SignalRationale(
        title="Amount is high for a new recipient",
        rationale=(
            "Compared against this device's own payment history. Used when no "
            "reputation is available for the recipient."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "amount_scaled_by_trust": SignalRationale(
        title="Amount weighed against the recipient's standing",
        rationale=(
            "The same sum is not equally risky to a long-known address and to a "
            "stranger. Only a well-regarded grade may reduce it below the flat weight."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "qr_provenance_missing": SignalRationale(
        title="Merchant-shaped QR without provenance fields",
        rationale=(
            "A priced merchant QR with no signature or organisation field. "
            "FinGuard checks presence only and cannot validate NPCI signatures."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "suspicious_note": SignalRationale(
        title="Pressure or pretext wording in the note",
        rationale=(
            "Advisories warn about urgency, KYC, reward and support wording. "
            "Matching it inside a payment note is FinGuard's own rule."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "identifier_relationship": SignalRationale(
        title="Linked to other seeded suspicious identifiers",
        rationale=(
            "The seeded demo set records relationships between fixture "
            "identifiers. Demo data, weighted accordingly."
        ),
        source=SourceCategory.FINGUARD_POLICY,
    ),
    "context_impersonation": SignalRationale(
        title="The message impersonates an organisation",
        rationale=(
            "From analysis of a message the user chose to share. Advisories "
            "warn that scammers may pose as an institution. Context never "
            "sets the verdict; it only adds weight."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "context_urgency": SignalRationale(
        title="The message applies urgency",
        rationale=(
            "Official advisories warn that scammers may manufacture time "
            "pressure so the payer acts before checking."
        ),
        source=SourceCategory.RBI_ADVISORY,
    ),
    "context_kyc_threat": SignalRationale(
        title="The message threatens KYC or account blocking",
        rationale=(
            "Advisories warn about KYC and account-blocking pretexts. "
            "Weighting it above generic urgency is FinGuard policy."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "context_reward_or_refund": SignalRationale(
        title="The message promises a refund or reward",
        rationale=(
            "Receiving money does not require you to approve a payment or "
            "enter a PIN. Low weight because genuine refund messages exist."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
    "context_suspicious_support": SignalRationale(
        title="The message claims to be customer support",
        rationale=(
            "Advisories warn that helpline numbers found by search may be "
            "fraudulent. Weighted as a prompt to verify the number."
        ),
        source=SourceCategory.NPCI_ADVISORY,
    ),
}


@dataclass(frozen=True, slots=True)
class PolicyBand:
    name: str
    minimum: int
    maximum: int
    meaning: str


def bands(thresholds: RiskThresholds) -> tuple[PolicyBand, ...]:
    return (
        PolicyBand(
            name="SAFE",
            minimum=0,
            maximum=thresholds.safe_max,
            meaning="Nothing strong enough to interrupt. Ordinary care still applies.",
        ),
        PolicyBand(
            name="CAUTION",
            minimum=thresholds.safe_max + 1,
            maximum=thresholds.caution_max,
            meaning="Enough accumulated to be worth confirming before paying.",
        ),
        PolicyBand(
            name="HIGH",
            minimum=thresholds.caution_max + 1,
            maximum=100,
            meaning="Stop and verify through a channel you already trust.",
        ),
    )


def weight_entries(weights: RiskWeights = WEIGHTS) -> list[dict[str, object]]:
    """Pair every configured weight with the reason it exists.

    Raises if the two ever drift apart, so an undocumented weight cannot ship.
    """
    fields = {field for field in weights.__dataclass_fields__}
    documented = set(SIGNAL_RATIONALES)
    missing = fields - documented
    extra = documented - fields
    if missing or extra:
        raise ValueError(
            f"policy card is out of step with RiskWeights; "
            f"undocumented={sorted(missing)} stale={sorted(extra)}"
        )
    entries: list[dict[str, object]] = []
    for field in sorted(fields):
        rationale = SIGNAL_RATIONALES[field]
        entries.append(
            {
                "field": field,
                "title": rationale.title,
                "points": getattr(weights, field),
                "rationale": rationale.rationale,
                "source_category": rationale.source.value,
                "source_link": SOURCE_LINKS[rationale.source],
            }
        )
    return entries
