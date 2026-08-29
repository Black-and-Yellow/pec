# Payee trust: a CIBIL-shaped score for a UPI ID

## The question, and the honest constraint

The judges asked whether a UPI ID can carry something like a CIBIL score —
how much has this payee transacted, how long has the ID existed.

It cannot, not literally. NPCI publishes no per-VPA transaction volume, no
registration date, and no merchant register. A stranger's UPI ledger is not
readable by any third party, so nobody outside a PSP can answer that question
directly, and any product claiming to is either lying or is a bank.

Saying only that would be a non-answer, though, because it mistakes the
mechanism for the idea.

## What a credit bureau actually is

CIBIL is not the RBI reading the banking system. It is a **bureau**: a private
company holding what its member banks voluntarily contribute, turned into a
score. Two consequences follow, and both are useful here:

1. A bureau does not need regulator access. It needs **members who contribute
   observations**, and enough of them that the aggregate says something.
2. A borrower nobody has lent to does not get a bad score. They get **`NH` —
   no history** — because "unknown" and "bad" are different claims.

FinGuard applies the same construction to payees. The network is the
membership; each safety check is a contributed observation.

## The five pillars

| Credit bureau concept | FinGuard payee trust | Source |
| --- | --- | --- |
| Account age | **Tenure** — days since the network first saw this payee | FinGuard ledger |
| Credit exposure | **Reach** — distinct devices that have checked it | FinGuard ledger |
| Repayment record | **Conduct** — how those checks resolved, plus user reports | FinGuard ledger |
| Recent enquiries | **Velocity** — a burst of first-time checks, i.e. a campaign | FinGuard ledger |
| *(no analogue)* | **Identity** — what the address structure itself discloses | The VPA string |

Identity is the pillar that carries a payee nobody has ever seen, and it is why
a first check still returns something useful on day one. It needs no network,
no history and no lookup — the address is evidence about itself:

- **Handle class.** Is `@okaxis` a real, recognised handle from a regulated
  provider, or something invented?
- **Lookalike handles.** `@oksbii` is one character from `@oksbi`. That is not
  a typo a legitimate payee makes.
- **Borrowed brands.** `sbi-refund@okaxis` invokes SBI from an address any
  individual can register in a minute. A genuine SBI collection account has no
  reason to. `sbi.collections@sbi` is fine — the handle backs the claim.
- **Pretext wording.** `kyc-verify-now@ybl` names *a reason to pay* rather than
  a payee. Real people and shops are named after themselves.
- **Phone-derived addresses.** `9876543210@ybl` is created and abandoned in
  minutes and carries no lasting identity.

## Scoring

Points are awarded out of 100: Identity 30, Tenure 25, Reach 20, Conduct 20,
Velocity 5. Grades follow the bands `A+ ≥ 85`, `A ≥ 65`, `B ≥ 50`, `C ≥ 35`,
`D` below.

Three rules keep the number honest:

**Thin files get no number.** Below three observed checks or seven days of
tenure, the four ledger pillars report `NO_DATA` and the grade is `NEW`. The
score is withheld entirely, exactly as a bureau returns `NH`. This matters: a
brand-new legitimate shop scores 93 on address structure alone, and displaying
that beside a `NEW` grade would read as an endorsement of an address nobody
has ever paid.

**Impersonation is not outweighable.** An address that borrows a brand or
imitates a handle is capped at 24 and graded `D`, no matter how much tenure and
reach it has accumulated. A long-lived scam VPA is still a scam VPA.

**A lookup is not an encounter.** `POST /api/v1/trust/lookup` deliberately does
not write to the ledger. If merely asking about an address counted as meeting
it, the ledger would measure curiosity rather than use, and anyone could
inflate a scam address into an established one by querying it in a loop. Only a
real risk check, from a distinct device, contributes.

## What this is not

The disclaimer travels inside the payload, so no screen can render the number
without its provenance:

> FinGuard network reputation, not an NPCI, bank, or credit bureau rating.

A high grade is not a guarantee that a payee is honest — it means many payers
have met this address over a long period without incident. A `NEW` grade is not
an accusation. It means there is no track record to lean on, which is exactly
what a payer should know before sending money to a stranger.

## The cold-start problem, stated plainly

The ledger pillars are worth little until the network has scale. That is not a
flaw in the design; it is the same position every bureau starts from, and it is
why Identity carries the first release on its own. Seeded demo data in
`backend/data/demo_payee_reputation.json` stands in for the network a
deployment would accumulate, and it is labelled as seeded wherever it surfaces.
