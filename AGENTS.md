# FinGuard engineering guardrails

- Keep the deterministic backend risk engine and `risk_policy.py` as the only score/verdict authority. AI may return only strict context signals.
- Treat QR, UPI URI, screenshot, OAuth, API, and provider data as untrusted. Never log or commit credentials, screenshots, passwords, tokens, or complete payment requests.
- Preserve explicit user confirmation before every UPI handoff, share, copy, or reporting-site action; never claim bank, NPCI, government, reversal, blocking, or reporting access.
- Prefer small typed Python/Dart changes, centralized policy, strict boundary schemas, and regression tests. Avoid new dependencies unless they materially simplify a verified requirement.
- Read `PLAN.md` before substantial work and update milestone evidence after validation. Use `scripts/verify.ps1` for the repeatable baseline.
- Use High-reasoning FinGuard implementer, QA, and reviewer agents for bounded work. Keep review agents read-only and preserve unrelated user changes.
