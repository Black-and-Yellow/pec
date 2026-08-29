"""Deterministic structural analysis of a UPI virtual payment address.

NPCI does not publish per-VPA transaction volume, registration date, or a
merchant register, so nothing here claims to read those. What a VPA does
carry in the clear is its own shape: which payment service provider issued
the handle, whether the local part is a disposable phone-derived identifier,
whether it borrows a bank or brand name it has no right to, and whether it
reads like a scam pretext. Those are checkable offline, on the string alone,
with no network call and no dependency on any registry FinGuard cannot see.

This module is the identity pillar of the payee trust score. It is
intentionally the only pillar that works for a VPA nobody has ever checked.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import StrEnum

VPA_SPLIT_PATTERN = re.compile(r"^(?P<local>[^@]+)@(?P<handle>[^@]+)$")
NUMERIC_LOCAL_PATTERN = re.compile(r"^\+?\d[\d\s.-]{5,}$")
DIGIT_RUN_PATTERN = re.compile(r"\d{6,}")
SEPARATOR_PATTERN = re.compile(r"[._\-\s]+")


class HandleClass(StrEnum):
    """How the handle issuer positions the addresses it hands out."""

    BANK = "BANK"
    CONSUMER_PSP = "CONSUMER_PSP"
    MERCHANT_PSP = "MERCHANT_PSP"
    UNRECOGNIZED = "UNRECOGNIZED"


HANDLE_CLASS_LABELS: dict[HandleClass, str] = {
    HandleClass.BANK: "bank-issued",
    HandleClass.CONSUMER_PSP: "consumer payment app",
    HandleClass.MERCHANT_PSP: "merchant aggregator",
    HandleClass.UNRECOGNIZED: "unrecognised",
}

# A curated registry of live UPI handles. It is deliberately incomplete: an
# absent handle scores as UNRECOGNIZED (no credit awarded) rather than as
# fraud, so a missing entry can only cost a legitimate payee a few points and
# can never manufacture a false accusation.
HANDLE_REGISTRY: dict[str, HandleClass] = {
    # Google Pay
    "okaxis": HandleClass.CONSUMER_PSP,
    "oksbi": HandleClass.CONSUMER_PSP,
    "okicici": HandleClass.CONSUMER_PSP,
    "okhdfcbank": HandleClass.CONSUMER_PSP,
    # PhonePe
    "ybl": HandleClass.CONSUMER_PSP,
    "ibl": HandleClass.CONSUMER_PSP,
    "axl": HandleClass.CONSUMER_PSP,
    # Paytm
    "paytm": HandleClass.CONSUMER_PSP,
    "ptaxis": HandleClass.CONSUMER_PSP,
    "ptsbi": HandleClass.CONSUMER_PSP,
    "pthdfc": HandleClass.CONSUMER_PSP,
    "ptyes": HandleClass.CONSUMER_PSP,
    # Other consumer apps
    "upi": HandleClass.CONSUMER_PSP,
    "apl": HandleClass.CONSUMER_PSP,
    "yapl": HandleClass.CONSUMER_PSP,
    "abfspay": HandleClass.CONSUMER_PSP,
    "freecharge": HandleClass.CONSUMER_PSP,
    "jupiteraxis": HandleClass.CONSUMER_PSP,
    "naviaxis": HandleClass.CONSUMER_PSP,
    "fam": HandleClass.CONSUMER_PSP,
    "superyes": HandleClass.CONSUMER_PSP,
    "timecosmos": HandleClass.CONSUMER_PSP,
    "slc": HandleClass.CONSUMER_PSP,
    "waaxis": HandleClass.CONSUMER_PSP,
    "waicici": HandleClass.CONSUMER_PSP,
    "wahdfcbank": HandleClass.CONSUMER_PSP,
    "wasbi": HandleClass.CONSUMER_PSP,
    # Banks
    "sbi": HandleClass.BANK,
    "hdfcbank": HandleClass.BANK,
    "icici": HandleClass.BANK,
    "axisbank": HandleClass.BANK,
    "kotak": HandleClass.BANK,
    "yesbank": HandleClass.BANK,
    "pnb": HandleClass.BANK,
    "barodampay": HandleClass.BANK,
    "cnrb": HandleClass.BANK,
    "unionbankofindia": HandleClass.BANK,
    "idfcbank": HandleClass.BANK,
    "federal": HandleClass.BANK,
    "indus": HandleClass.BANK,
    "rbl": HandleClass.BANK,
    "uco": HandleClass.BANK,
    "cbin": HandleClass.BANK,
    "kbl": HandleClass.BANK,
    "dbs": HandleClass.BANK,
    "idbi": HandleClass.BANK,
    "citi": HandleClass.BANK,
    "equitas": HandleClass.BANK,
    "airtel": HandleClass.BANK,
    "jio": HandleClass.BANK,
    # Merchant aggregators
    "ptys": HandleClass.MERCHANT_PSP,
    "rzp": HandleClass.MERCHANT_PSP,
    "payu": HandleClass.MERCHANT_PSP,
    "cashfree": HandleClass.MERCHANT_PSP,
    "yesbankltd": HandleClass.MERCHANT_PSP,
    "hdfcbankltd": HandleClass.MERCHANT_PSP,
    "icicibank": HandleClass.MERCHANT_PSP,
    "axisb": HandleClass.MERCHANT_PSP,
    "pinelabs": HandleClass.MERCHANT_PSP,
    "mairtel": HandleClass.MERCHANT_PSP,
}

# Brand tokens a fraudulent local part borrows to look official. A local part
# claiming one of these while sitting on a personal consumer handle is the
# most common impersonation shape in Indian UPI fraud.
PROTECTED_BRAND_TOKENS: frozenset[str] = frozenset(
    {
        "sbi",
        "statebank",
        "hdfc",
        "icici",
        "axis",
        "kotak",
        "pnb",
        "boi",
        "bob",
        "baroda",
        "canara",
        "union",
        "idfc",
        "yesbank",
        "indusind",
        "rbl",
        "federal",
        "npci",
        "bhim",
        "rbi",
        "paytm",
        "phonepe",
        "gpay",
        "googlepay",
        "amazonpay",
        "bharatpe",
        "razorpay",
        "irctc",
        "lic",
        "epfo",
        "uidai",
        "aadhaar",
        "incometax",
        "gst",
        "customs",
        "police",
        "cbi",
        "cybercrime",
        "court",
        "army",
        "airtel",
        "jio",
        "vodafone",
        "bsnl",
        "tneb",
        "electricity",
        "postoffice",
    }
)

# Pretext vocabulary. These words describe a reason to pay rather than a
# person or a shop, and a genuine payee almost never needs one in their VPA.
PRETEXT_TOKENS: frozenset[str] = frozenset(
    {
        "kyc",
        "kycupdate",
        "verify",
        "verified",
        "verification",
        "validate",
        "refund",
        "refunds",
        "reward",
        "rewards",
        "prize",
        "lottery",
        "lucky",
        "winner",
        "cashback",
        "bonus",
        "gift",
        "offer",
        "free",
        "claim",
        "support",
        "helpdesk",
        "helpline",
        "customercare",
        "care",
        "service",
        "official",
        "authorised",
        "authorized",
        "secure",
        "security",
        "safety",
        "update",
        "unblock",
        "block",
        "reactivate",
        "penalty",
        "fine",
        "dues",
        "urgent",
        "emergency",
        "insurance",
        "policy",
        "loan",
        "approval",
        "trading",
        "investment",
        "profit",
        "task",
        "parttime",
        "workfromhome",
    }
)

KNOWN_HANDLE_TOKENS: frozenset[str] = frozenset(HANDLE_REGISTRY)

IDENTITY_MAXIMUM = 30


@dataclass(frozen=True, slots=True)
class IdentityFinding:
    """One structural observation, with the points it moved and why."""

    code: str
    label: str
    points: int
    evidence: str


@dataclass(frozen=True, slots=True)
class VpaIdentity:
    """The complete structural read of one VPA."""

    vpa: str
    local_part: str
    handle: str
    handle_class: HandleClass
    points: int
    maximum: int
    findings: tuple[IdentityFinding, ...]
    impersonated_brand: str | None
    pretext_token: str | None
    lookalike_of: str | None

    @property
    def is_impersonation(self) -> bool:
        return self.impersonated_brand is not None or self.lookalike_of is not None


def _tokens(local_part: str) -> list[str]:
    return [token for token in SEPARATOR_PATTERN.split(local_part.lower()) if token]


def _collapsed(local_part: str) -> str:
    return SEPARATOR_PATTERN.sub("", local_part.lower())


def _edit_distance_within(candidate: str, target: str, limit: int) -> bool:
    """Bounded Levenshtein check. Cheap because both strings are handles."""
    if abs(len(candidate) - len(target)) > limit:
        return False
    previous = list(range(len(target) + 1))
    for index, source_character in enumerate(candidate, start=1):
        current = [index]
        for target_index, target_character in enumerate(target, start=1):
            current.append(
                min(
                    previous[target_index] + 1,
                    current[target_index - 1] + 1,
                    previous[target_index - 1] + (source_character != target_character),
                )
            )
        if min(current) > limit:
            return False
        previous = current
    return previous[-1] <= limit


def _lookalike_handle(handle: str) -> str | None:
    if handle in HANDLE_REGISTRY or len(handle) < 3:
        return None
    for known in sorted(KNOWN_HANDLE_TOKENS):
        if len(known) >= 3 and _edit_distance_within(handle, known, 1):
            return known
    return None


def _borrowed_brand(local_part: str, handle: str, handle_class: HandleClass) -> str | None:
    """A brand token in the local part that the handle does not back up.

    ``sbi@oksbi`` is fine: the handle is the bank own handle. ``sbi-refund@okaxis``
    is not: it invokes SBI from an address any individual can create in a
    minute on a different provider.
    """
    collapsed_handle = handle.lower()
    for token in _tokens(local_part):
        if token not in PROTECTED_BRAND_TOKENS:
            continue
        if token in collapsed_handle:
            continue
        if handle_class is HandleClass.BANK and collapsed_handle.startswith(token[:3]):
            continue
        return token
    return None


def _pretext_token(local_part: str) -> str | None:
    for token in _tokens(local_part):
        if token in PRETEXT_TOKENS:
            return token
    collapsed = _collapsed(local_part)
    # Catch run-together forms such as "kycupdatecell" that survive splitting.
    for token in sorted(PRETEXT_TOKENS, key=len, reverse=True):
        if len(token) >= 5 and token in collapsed:
            return token
    return None


def analyze_vpa(vpa: str) -> VpaIdentity:
    """Score the structure of ``vpa`` out of :data:`IDENTITY_MAXIMUM`."""
    normalized = vpa.strip().lower()
    match = VPA_SPLIT_PATTERN.match(normalized)
    if match is None:
        return VpaIdentity(
            vpa=normalized,
            local_part=normalized,
            handle="",
            handle_class=HandleClass.UNRECOGNIZED,
            points=0,
            maximum=IDENTITY_MAXIMUM,
            findings=(
                IdentityFinding(
                    code="MALFORMED_VPA",
                    label="Address is not a well-formed UPI ID",
                    points=0,
                    evidence="A UPI ID must read as name@handle.",
                ),
            ),
            impersonated_brand=None,
            pretext_token=None,
            lookalike_of=None,
        )

    local_part = match.group("local")
    handle = match.group("handle")
    handle_class = HANDLE_REGISTRY.get(handle, HandleClass.UNRECOGNIZED)
    lookalike = _lookalike_handle(handle)
    borrowed = _borrowed_brand(local_part, handle, handle_class)
    pretext = _pretext_token(local_part)

    findings: list[IdentityFinding] = []
    points = 0

    if lookalike is not None:
        findings.append(
            IdentityFinding(
                code="LOOKALIKE_HANDLE",
                label="Handle is one character away from a real payment handle",
                points=0,
                evidence=(
                    f"@{handle} is not a registered handle but differs from "
                    f"@{lookalike} by a single character."
                ),
            )
        )
    elif handle_class is HandleClass.UNRECOGNIZED:
        findings.append(
            IdentityFinding(
                code="UNRECOGNIZED_HANDLE",
                label="Payment handle is not in the FinGuard registry",
                points=0,
                evidence=(
                    f"@{handle} is not one of the handles FinGuard recognises. That is "
                    "not proof of fraud, but it carries no assurance either."
                ),
            )
        )
    else:
        awarded = 12 if handle_class is HandleClass.MERCHANT_PSP else 10
        points += awarded
        findings.append(
            IdentityFinding(
                code="RECOGNIZED_HANDLE",
                label=f"Issued on a recognised {HANDLE_CLASS_LABELS[handle_class]} handle",
                points=awarded,
                evidence=(
                    f"@{handle} is a handle FinGuard recognises, issued by a regulated "
                    "payment service provider."
                ),
            )
        )

    if borrowed is not None:
        findings.append(
            IdentityFinding(
                code="BORROWED_BRAND",
                label="Address borrows an organisation name it is not issued by",
                points=0,
                evidence=(
                    f"The name before the @ claims {borrowed}, but the address sits on "
                    f"@{handle}, which anyone can register. A real {borrowed} collection "
                    "account would not need to."
                ),
            )
        )
    else:
        points += 6
        findings.append(
            IdentityFinding(
                code="NO_BORROWED_BRAND",
                label="Does not borrow a bank or government name",
                points=6,
                evidence="The name before the @ makes no organisational claim it cannot back.",
            )
        )

    if pretext is not None:
        findings.append(
            IdentityFinding(
                code="PRETEXT_IN_ADDRESS",
                label="Address names a reason to pay rather than a payee",
                points=0,
                evidence=(
                    f"The word {pretext} appears in the address itself. Genuine payees are "
                    "named after a person or a shop, not after the excuse for the payment."
                ),
            )
        )
    else:
        points += 6
        findings.append(
            IdentityFinding(
                code="NO_PRETEXT_IN_ADDRESS",
                label="Address reads as a payee, not as a pretext",
                points=6,
                evidence="No KYC, refund, reward, or support wording appears in the address.",
            )
        )

    disposable = bool(
        NUMERIC_LOCAL_PATTERN.match(local_part) or DIGIT_RUN_PATTERN.search(local_part)
    )
    if disposable:
        findings.append(
            IdentityFinding(
                code="PHONE_DERIVED_ADDRESS",
                label="Address is derived from a phone number",
                points=0,
                evidence=(
                    "The name before the @ is a phone number. These are created and "
                    "abandoned in minutes, so they carry no lasting identity."
                ),
            )
        )
    else:
        points += 6
        findings.append(
            IdentityFinding(
                code="NAMED_ADDRESS",
                label="Address is a stable name rather than a phone number",
                points=6,
                evidence="The name before the @ is not a bare phone number.",
            )
        )

    return VpaIdentity(
        vpa=normalized,
        local_part=local_part,
        handle=handle,
        handle_class=handle_class,
        points=min(points, IDENTITY_MAXIMUM),
        maximum=IDENTITY_MAXIMUM,
        findings=tuple(findings),
        impersonated_brand=borrowed,
        pretext_token=pretext,
        lookalike_of=lookalike,
    )


def borrowed_brand_in_claimed_name(claimed_name: str, vpa: str) -> str | None:
    """Return a protected name token that the VPA handle does not support."""
    # QR names are unverified metadata. Reuse the address rule so protected
    # tokens and the handle-backing exception remain one source of truth.
    identity = analyze_vpa(vpa)
    return _borrowed_brand(claimed_name, identity.handle, identity.handle_class)
