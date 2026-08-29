"""A credit-bureau-shaped reputation score for a UPI ID.

The judges' question was whether a UPI ID can carry something like a CIBIL
score: how much has this payee transacted, how long has the ID existed. NPCI
publishes neither, and no third party can read a stranger's UPI ledger, so a
literal answer is not available to anyone outside a PSP.

What is available is the shape of the bureau itself. CIBIL is not a regulator
reading the banking system; it is a bureau holding what its member banks
contribute, and a borrower nobody has lent to gets ``NH`` rather than a bad
score. FinGuard applies that same construction to payees:

===============  ====================================================
Credit bureau    FinGuard payee trust
===============  ====================================================
Account age      TENURE: days since the network first saw this payee
Credit exposure  REACH: distinct devices that have checked it
Repayment        CONDUCT: how those checks resolved, plus user reports
Recent enquiry   VELOCITY: a burst of first-time checks, as a campaign
(no analogue)    IDENTITY: what the address structure itself discloses
===============  ====================================================

IDENTITY is the pillar that carries a payee nobody has seen before, and it is
the reason a first check still returns something useful. The four ledger
pillars report ``NO_DATA`` until the network has enough to say, and the score
is normalised over the pillars that could actually be assessed, so a genuine
new payee grades ``NEW`` rather than ``D``.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Literal

from app.repositories.reputation_repository import ReputationSnapshot
from app.schemas import (
    PayeeTrust,
    TrustGrade,
    TrustPillar,
    TrustPillarCode,
    TrustPillarStatus,
)
from app.services.vpa_identity import VpaIdentity, analyze_vpa

TENURE_MAXIMUM = 25
REACH_MAXIMUM = 20
CONDUCT_MAXIMUM = 20
VELOCITY_MAXIMUM = 5

# Below this many observed checks the ledger pillars say nothing. Three is
# deliberately low: it is enough for "more than one stranger has seen this"
# without pretending a handful of checks is a payment history.
MINIMUM_OBSERVATIONS_FOR_HISTORY = 3
MINIMUM_DAYS_FOR_TENURE = 7

# An impersonating or reported address cannot climb out of the bottom band on
# the strength of tenure and reach. A long-lived scam VPA is still a scam VPA.
IMPERSONATION_SCORE_CEILING = 24

# Identity points below this mean the address itself raised at least one
# structural concern: a pretext word, a disposable phone-derived local part, or
# a handle no known PSP issues. A clean address scores 28 or better.
#
# This threshold decides whether a thin file still withholds its number. The
# withholding rule exists because identity alone can score 93 on a shop nobody
# has ever paid, and that number would be read as an endorsement. That protects
# a *good* structure. Withholding a *low* score protects the scammer instead:
# it hands 'kyc-verify-now@ybl' the same courteous NEW as a real new bakery.
# So a thin file with a structural concern is graded on what its own text
# discloses, which needs no ledger to be true.
IDENTITY_CONCERN_THRESHOLD = 24

DISCLAIMER = (
    "FinGuard network reputation, not an NPCI, bank, or credit bureau rating. "
    "It reflects what this network has observed about the address plus what the "
    "address itself discloses. A high grade is not a guarantee, and a NEW grade "
    "means no track record, not wrongdoing."
)


@dataclass(frozen=True, slots=True)
class TrustInputs:
    vpa: str
    reputation: ReputationSnapshot
    seeded_indicator_label: str | None = None


def _tenure_points(days: int) -> int:
    if days >= 365:
        return 25
    if days >= 180:
        return 20
    if days >= 90:
        return 15
    if days >= 30:
        return 10
    if days >= MINIMUM_DAYS_FOR_TENURE:
        return 5
    return 0


def _reach_points(devices: int) -> int:
    if devices >= 100:
        return 20
    if devices >= 25:
        return 16
    if devices >= 10:
        return 12
    if devices >= 3:
        return 7
    if devices >= 1:
        return 3
    return 0


def _status(points: int, maximum: int) -> TrustPillarStatus:
    if maximum == 0:
        return TrustPillarStatus.NO_DATA
    ratio = points / maximum
    if ratio >= 0.7:
        return TrustPillarStatus.STRONG
    if ratio >= 0.35:
        return TrustPillarStatus.NEUTRAL
    return TrustPillarStatus.WEAK


def _plural(count: int, singular: str, plural: str) -> str:
    return f"{count} {singular if count == 1 else plural}"


class TrustScorer:
    """Builds a :class:`PayeeTrust` report from identity plus ledger standing."""

    def score(self, inputs: TrustInputs) -> PayeeTrust:
        identity = analyze_vpa(inputs.vpa)
        reputation = inputs.reputation
        has_history = (
            reputation.check_count >= MINIMUM_OBSERVATIONS_FOR_HISTORY
            and reputation.observed_days >= MINIMUM_DAYS_FOR_TENURE
        )

        pillars: list[TrustPillar] = [self._identity_pillar(identity)]
        if has_history:
            pillars.extend(
                (
                    self._tenure_pillar(reputation),
                    self._reach_pillar(reputation),
                    self._conduct_pillar(reputation, inputs.seeded_indicator_label),
                    self._velocity_pillar(reputation),
                )
            )
        else:
            pillars.extend(self._no_history_pillars(reputation))

        assessed_points = sum(pillar.points for pillar in pillars)
        assessable_maximum = sum(
            pillar.maximum
            for pillar in pillars
            if pillar.status is not TrustPillarStatus.NO_DATA
        )
        score = round(100 * assessed_points / assessable_maximum)

        adverse = (
            identity.is_impersonation
            or inputs.seeded_indicator_label is not None
            or reputation.reported_count > 0
        )
        if adverse:
            score = min(score, IMPERSONATION_SCORE_CEILING)

        thin_file = not has_history
        grade = self._grade(score, thin_file=thin_file, adverse=adverse)
        return PayeeTrust(
            vpa=identity.vpa,
            # A thin file reports its grade and its pillars but no number.
            # Identity alone can score 93 on a shop nobody has ever paid, and
            # that number would be read as a recommendation.
            #
            # Grading such a file on identity alone was tried and is wrong: the
            # score normalises over assessable pillars, so a pretext address
            # scoring 22 of 30 on structure alone reads as 73 and grades A. The
            # concern belongs in the pillar evidence and in the risk engine,
            # which is where it now lives - not in an inflated percentage.
            score=None if thin_file and not adverse else score,
            grade=grade,
            headline=self._headline(grade, identity, reputation),
            thin_file=thin_file,
            impersonation=identity.is_impersonation,
            confidence=self._confidence(assessable_maximum),
            pillars=pillars,
            assessed_points=assessed_points,
            assessable_maximum=assessable_maximum,
            first_seen_at=reputation.first_seen_at,
            observed_days=reputation.observed_days,
            check_count=reputation.check_count,
            distinct_device_count=reputation.distinct_device_count,
            reported_count=reputation.reported_count,
            disclaimer=DISCLAIMER,
        )

    def _identity_pillar(self, identity: VpaIdentity) -> TrustPillar:
        concerns = [
            finding.evidence for finding in identity.findings if finding.points == 0
        ]
        evidence = (
            " ".join(concerns)
            if concerns
            else "The address structure raised none of the checks FinGuard applies to it."
        )
        # An address raising a concern must never read as strong. Three of the
        # four identity checks pass for almost any address, so a single serious
        # failure still leaves a ratio in the strong band: a pretext address
        # scored 22 of 30 and rendered a healthy green bar directly above the
        # sentence explaining why the address is suspect. The status has to
        # agree with the evidence printed beside it.
        status = _status(identity.points, identity.maximum)
        if identity.is_impersonation:
            status = TrustPillarStatus.WEAK
        elif concerns and status is TrustPillarStatus.STRONG:
            status = TrustPillarStatus.NEUTRAL
        return TrustPillar(
            code=TrustPillarCode.IDENTITY,
            label="Address identity",
            points=identity.points,
            maximum=identity.maximum,
            status=status,
            evidence=evidence[:400],
        )

    def _tenure_pillar(self, reputation: ReputationSnapshot) -> TrustPillar:
        days = reputation.observed_days
        points = _tenure_points(days)
        return TrustPillar(
            code=TrustPillarCode.TENURE,
            label="How long the network has known it",
            points=points,
            maximum=TENURE_MAXIMUM,
            status=_status(points, TENURE_MAXIMUM),
            evidence=(
                f"First seen by the FinGuard network {_plural(days, 'day', 'days')} ago. "
                "Fraud addresses are usually days old because they are burned and replaced."
            ),
        )

    def _reach_pillar(self, reputation: ReputationSnapshot) -> TrustPillar:
        devices = reputation.distinct_device_count
        points = _reach_points(devices)
        return TrustPillar(
            code=TrustPillarCode.REACH,
            label="How many people have met it",
            points=points,
            maximum=REACH_MAXIMUM,
            status=_status(points, REACH_MAXIMUM),
            evidence=(
                f"Checked from {_plural(devices, 'distinct device', 'distinct devices')}. "
                "A real shop accumulates many payers; a one-victim address does not."
            ),
        )

    def _conduct_pillar(
        self,
        reputation: ReputationSnapshot,
        seeded_indicator_label: str | None,
    ) -> TrustPillar:
        if seeded_indicator_label is not None:
            return TrustPillar(
                code=TrustPillarCode.CONDUCT,
                label="How those encounters went",
                points=0,
                maximum=CONDUCT_MAXIMUM,
                status=TrustPillarStatus.WEAK,
                evidence=(
                    f"This address matches {seeded_indicator_label} in FinGuard's clearly "
                    "labelled seeded demo indicator set."
                ),
            )
        checks = max(1, reputation.check_count)
        # A prepared incident report is a person deciding this address harmed
        # them, so it counts for far more than an automated high-risk verdict.
        adverse_weight = reputation.high_count + (3 * reputation.reported_count)
        adverse_ratio = min(1.0, adverse_weight / checks)
        points = round(CONDUCT_MAXIMUM * (1 - adverse_ratio))
        if reputation.reported_count > 0:
            evidence = (
                f"{_plural(reputation.reported_count, 'user has', 'users have')} prepared an "
                f"incident report naming this address, across {reputation.check_count} checks."
            )
        elif reputation.high_count > 0:
            evidence = (
                f"{reputation.high_count} of {reputation.check_count} checks on this address "
                "ended at high risk."
            )
        else:
            evidence = (
                f"None of the {reputation.check_count} checks on this address ended at high "
                "risk, and nobody has reported it."
            )
        return TrustPillar(
            code=TrustPillarCode.CONDUCT,
            label="How those encounters went",
            points=points,
            maximum=CONDUCT_MAXIMUM,
            status=_status(points, CONDUCT_MAXIMUM),
            evidence=evidence,
        )

    def _velocity_pillar(self, reputation: ReputationSnapshot) -> TrustPillar:
        devices = reputation.distinct_device_count
        recent = reputation.recent_new_device_count
        if devices < 5:
            return TrustPillar(
                code=TrustPillarCode.VELOCITY,
                label="Sudden spread",
                points=3,
                maximum=VELOCITY_MAXIMUM,
                status=TrustPillarStatus.NEUTRAL,
                evidence=(
                    "Too few payers so far to tell a steady payee from a campaign burst."
                ),
            )
        burst = recent / devices
        if burst > 0.6 and recent >= 10:
            points = 0
            evidence = (
                f"{recent} of {devices} payers met this address in the last week. That "
                "concentration is what a fresh scam campaign looks like."
            )
        elif burst > 0.35:
            points = 2
            evidence = (
                f"{recent} of {devices} payers are from the last week, which is faster "
                "growth than an established payee usually shows."
            )
        else:
            points = VELOCITY_MAXIMUM
            evidence = (
                f"Only {recent} of {devices} payers are new this week, so its use is steady "
                "rather than a burst."
            )
        return TrustPillar(
            code=TrustPillarCode.VELOCITY,
            label="Sudden spread",
            points=points,
            maximum=VELOCITY_MAXIMUM,
            status=_status(points, VELOCITY_MAXIMUM),
            evidence=evidence,
        )

    def _no_history_pillars(
        self, reputation: ReputationSnapshot
    ) -> list[TrustPillar]:
        if reputation.is_unknown:
            tenure_evidence = "No FinGuard device has ever checked this address before."
            reach_evidence = "Nobody in the network has met this payee yet."
            conduct_evidence = "There are no past encounters to judge."
        else:
            tenure_evidence = (
                f"First seen {_plural(reputation.observed_days, 'day', 'days')} ago, over "
                f"{_plural(reputation.check_count, 'check', 'checks')}. That is not yet enough "
                "history to grade."
            )
            reach_evidence = (
                f"Seen by {_plural(reputation.distinct_device_count, 'device', 'devices')} so "
                "far, which is too few to read as reach."
            )
            conduct_evidence = (
                f"Only {_plural(reputation.check_count, 'check', 'checks')} on record, too few "
                "to describe a pattern."
            )
        return [
            TrustPillar(
                code=TrustPillarCode.TENURE,
                label="How long the network has known it",
                points=0,
                maximum=TENURE_MAXIMUM,
                status=TrustPillarStatus.NO_DATA,
                evidence=tenure_evidence,
            ),
            TrustPillar(
                code=TrustPillarCode.REACH,
                label="How many people have met it",
                points=0,
                maximum=REACH_MAXIMUM,
                status=TrustPillarStatus.NO_DATA,
                evidence=reach_evidence,
            ),
            TrustPillar(
                code=TrustPillarCode.CONDUCT,
                label="How those encounters went",
                points=0,
                maximum=CONDUCT_MAXIMUM,
                status=TrustPillarStatus.NO_DATA,
                evidence=conduct_evidence,
            ),
            TrustPillar(
                code=TrustPillarCode.VELOCITY,
                label="Sudden spread",
                points=0,
                maximum=VELOCITY_MAXIMUM,
                status=TrustPillarStatus.NO_DATA,
                evidence="Not enough payers to compare this week against any baseline.",
            ),
        ]

    @staticmethod
    def _confidence(assessable_maximum: int) -> Literal["LOW", "MEDIUM", "HIGH"]:
        if assessable_maximum >= 90:
            return "HIGH"
        if assessable_maximum >= 50:
            return "MEDIUM"
        return "LOW"

    @staticmethod
    def _grade(score: int, *, thin_file: bool, adverse: bool) -> TrustGrade:
        if adverse:
            return TrustGrade.D
        if thin_file:
            return TrustGrade.NEW
        if score >= 85:
            return TrustGrade.A_PLUS
        if score >= 65:
            return TrustGrade.A
        if score >= 50:
            return TrustGrade.B
        if score >= 35:
            return TrustGrade.C
        return TrustGrade.D

    @staticmethod
    def _headline(
        grade: TrustGrade,
        identity: VpaIdentity,
        reputation: ReputationSnapshot,
    ) -> str:
        if identity.lookalike_of is not None:
            return "This address imitates a real payment handle"
        if identity.impersonated_brand is not None:
            return "This address claims a name it is not issued by"
        if reputation.reported_count > 0:
            return "Someone in the network has reported this address"
        return {
            TrustGrade.A_PLUS: "Long-established payee across many payers",
            TrustGrade.A: "Established payee with a clean record here",
            TrustGrade.B: "Some track record, nothing adverse on file",
            TrustGrade.C: "Thin track record and a weak address structure",
            TrustGrade.D: "Little to trust in this address",
            TrustGrade.NEW: "No track record yet: treat this as a stranger",
        }[grade]


def unknown_payee_trust(vpa: str, *, now: datetime | None = None) -> PayeeTrust:
    """Trust report for a payee the ledger cannot be consulted about."""
    from app.repositories.reputation_repository import unknown_snapshot

    _ = now or datetime.now(UTC)
    return TrustScorer().score(TrustInputs(vpa=vpa, reputation=unknown_snapshot(vpa)))
