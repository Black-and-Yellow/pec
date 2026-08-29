"""Work out what a user actually pasted, before deciding what to do with it.

People do not arrive holding a tidy ``upi://pay`` URI. A seller sends a bare
UPI ID over WhatsApp. A caller reads out a phone number. Somebody forwards a
whole payment link. Asking the user to classify their own input first - "is
this a link or an ID?" - puts the burden in the wrong place, so this module
takes the burden instead.

Nothing here contacts a network or claims an identity is genuine. It decides
only what shape a string is, which is enough to route it to the right check.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from enum import StrEnum

from app.schemas import VPA_PATTERN

# An Indian mobile number is ten digits opening with 6, 7, 8 or 9. The optional
# prefixes are the ways people actually write one down.
MOBILE_PATTERN = re.compile(r"^(?:\+?91|0)?([6-9][0-9]{9})$")
SEPARATORS_PATTERN = re.compile(r"[\s\-().]+")
UPI_SCHEME_PATTERN = re.compile(r"^upi://", re.IGNORECASE)

# Handles that issue phone-number-based addresses, most common first. A phone
# number alone is not payable; these are the addresses one might become. The
# list is short on purpose - each entry costs a ledger read, and these cover
# the overwhelming majority of phone-derived VPAs in circulation.
PHONE_VPA_HANDLES: tuple[str, ...] = (
    "ybl",
    "paytm",
    "axl",
    "ibl",
    "upi",
    "apl",
    "okaxis",
    "oksbi",
)


class IdentifierKind(StrEnum):
    UPI_LINK = "UPI_LINK"
    UPI_ID = "UPI_ID"
    MOBILE = "MOBILE"
    UNSUPPORTED = "UNSUPPORTED"


@dataclass(frozen=True, slots=True)
class Identifier:
    """What the pasted text turned out to be."""

    kind: IdentifierKind
    #: The cleaned value: a URI, a normalised VPA, or ten digits.
    value: str
    #: Present only for MOBILE: the addresses this number might be payable at.
    candidate_vpas: tuple[str, ...] = ()
    #: Why an input could not be used, in words meant for the person who typed it.
    reason: str | None = None


def _strip_invisible(text: str) -> str:
    """Remove formatting characters that survive a copy-paste.

    Copying a number out of a chat app routinely brings along a zero-width
    space or a directional mark. The user sees a phone number and would be
    right to expect it to work.
    """
    normalized = unicodedata.normalize("NFKC", text)
    return "".join(
        character for character in normalized if unicodedata.category(character) != "Cf"
    )


def classify(raw: str) -> Identifier:
    """Decide what a pasted string is. Never raises: UNSUPPORTED explains itself."""
    text = _strip_invisible(raw).strip()
    if not text:
        return Identifier(
            kind=IdentifierKind.UNSUPPORTED,
            value="",
            reason="Nothing was entered.",
        )
    if len(text) > 2_048:
        return Identifier(
            kind=IdentifierKind.UNSUPPORTED,
            value="",
            reason="That is too long to be a UPI ID, a link, or a phone number.",
        )

    if UPI_SCHEME_PATTERN.match(text):
        return Identifier(kind=IdentifierKind.UPI_LINK, value=text)

    # A VPA is checked before a phone number, because a phone-derived address
    # such as 9876543210@ybl is a VPA and should be read as one.
    candidate = text.lower()
    if VPA_PATTERN.fullmatch(candidate):
        return Identifier(kind=IdentifierKind.UPI_ID, value=candidate)

    digits = SEPARATORS_PATTERN.sub("", text)
    mobile_match = MOBILE_PATTERN.fullmatch(digits)
    if mobile_match is not None:
        number = mobile_match.group(1)
        return Identifier(
            kind=IdentifierKind.MOBILE,
            value=number,
            candidate_vpas=tuple(f"{number}@{handle}" for handle in PHONE_VPA_HANDLES),
        )

    if "@" in text:
        return Identifier(
            kind=IdentifierKind.UNSUPPORTED,
            value=text[:64],
            reason=(
                "That looks like a UPI ID but is not a valid one. A UPI ID reads "
                "name@handle, using only letters, numbers, dots, hyphens and "
                "underscores."
            ),
        )
    if any(character.isdigit() for character in text):
        return Identifier(
            kind=IdentifierKind.UNSUPPORTED,
            value=text[:64],
            reason=(
                "That is not a UPI ID, a payment link, or an Indian mobile number. "
                "A mobile number is ten digits starting with 6, 7, 8 or 9."
            ),
        )
    return Identifier(
        kind=IdentifierKind.UNSUPPORTED,
        value=text[:64],
        reason=(
            "Paste a UPI ID such as name@okaxis, a upi:// payment link, or a "
            "ten-digit mobile number."
        ),
    )
