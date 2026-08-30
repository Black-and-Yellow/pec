"""Detect the collection-account shape in a payee's FinGuard check history.

FinGuard never sees a payment. It sees safety checks: somebody pointed the app
at an address before deciding what to do. Everything below is measured in
those checks, and the wording has to keep saying so - "payers" and "collected"
would claim a view of money movement that only a bank has.

A mule account is not a scam address in the sense the fraud list means. It is
usually a real account belonging to a real, often coerced or recruited person,
rented out to receive other people's stolen money and pass it on. Nothing in
the VPA string gives that away: the address is structurally innocent, the
handle is a normal consumer PSP, and the local part is somebody's actual name.
The identity pillar cannot see it, and it never will.

What FinGuard can see is the *lookup pattern*. An address being circulated by
a campaign gets checked by many unrelated people who each look once and never
return, inside a short window, with no history behind it. A real shop looks
nothing like that: the people checking it accumulate gradually and a
meaningful share come back.

This is check-pattern evidence, not transaction evidence. It is consistent
with a collection account and is not proof that one rupee moved.

FinGuard already records every one of those quantities for the reach, tenure
and velocity pillars. This module reads them as one shape instead of four
independent numbers.

Two deliberate limits. This reports a *pattern*, never a verdict: a genuinely
popular new merchant - a stall that goes viral, a fundraiser - can produce the
same shape, and the wording that reaches the user has to survive being wrong.
And it stays silent below a floor of observations, because three strangers
paying a new address is not a pattern, it is a Tuesday.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.repositories.reputation_repository import ReputationSnapshot

# These four thresholds are set so that no single observer can move the
# verdict. A payer's own checks land in the same ledger everyone else's do, so
# thresholds tuned to the edge of a real payee's shape would flip the moment
# that payer looked twice - which is how an earlier revision of this file made
# an honest marketplace seller read as a mule on the second check and clean
# again on the third. A signal that swings on one observation is not a signal.
# The bar is therefore set to demand an unambiguous pattern with margin, and
# test_one_payers_checks_never_flip_the_verdict pins that property directly.

# Below this many distinct check sources there is no shape to read, only noise.
MINIMUM_CHECK_SOURCES = 8

# An address the network has watched for longer than this has a history, and a
# history is the thing a freshly rented collection account does not have.
MAXIMUM_TENURE_DAYS = 30

# Share of check sources that never came back. A shop is looked up again by
# the same people; a circulated address usually is not.
MINIMUM_SINGLE_VISIT_RATIO = 0.85

# Share of the total reach that arrived inside the recent window. Campaigns
# run in bursts because an address is abandoned once it is reported.
MINIMUM_BURST_RATIO = 0.7


@dataclass(frozen=True, slots=True)
class MuleSignature:
    """The collection-account read of one payee's ledger."""

    matched: bool
    check_source_count: int
    single_visit_ratio: float
    burst_ratio: float
    tenure_days: int
    evidence: str


def _ratio(numerator: int, denominator: int) -> float:
    if denominator <= 0:
        return 0.0
    return numerator / denominator


def assess(snapshot: ReputationSnapshot | None) -> MuleSignature:
    """Read the mule shape from a payee's ledger, if there is enough to read."""
    if snapshot is None or snapshot.is_unknown:
        return MuleSignature(
            matched=False,
            check_source_count=0,
            single_visit_ratio=0.0,
            burst_ratio=0.0,
            tenure_days=0,
            evidence="The network has no record for this address.",
        )

    sources = snapshot.distinct_device_count
    # Each payer contributes at least one check, so a ratio at 1.0 means nobody
    # ever checked this address twice and a ratio near 0 means heavy repeat use.
    single_visit = _ratio(sources, snapshot.check_count)
    burst = _ratio(snapshot.recent_new_device_count, sources)
    tenure = snapshot.observed_days

    matched = (
        sources >= MINIMUM_CHECK_SOURCES
        and tenure <= MAXIMUM_TENURE_DAYS
        and single_visit >= MINIMUM_SINGLE_VISIT_RATIO
        and burst >= MINIMUM_BURST_RATIO
    )

    if not matched:
        return MuleSignature(
            matched=False,
            check_source_count=sources,
            single_visit_ratio=single_visit,
            burst_ratio=burst,
            tenure_days=tenure,
            evidence="This address does not show the collection-account pattern.",
        )

    window = "today" if tenure == 0 else f"in {tenure} day(s)"
    # Kept short enough to satisfy the evidence field's 300-character limit
    # even with four-digit counts; test_evidence_fits_the_schema pins that.
    evidence = (
        f"{sources} independent checks looked up this address {window}, "
        f"{round(single_visit * 100)}% of them once only. Circulated scam "
        "addresses are checked like this, then go quiet. Check-pattern evidence, "
        "not bank transaction data: a busy new business looks the same, so treat "
        "it as a reason to confirm, not as proof of fraud."
    )
    return MuleSignature(
        matched=True,
        check_source_count=sources,
        single_visit_ratio=single_visit,
        burst_ratio=burst,
        tenure_days=tenure,
        evidence=evidence,
    )
