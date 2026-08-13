# FinGuard acceptance gates

## Product invariants

- Accept and hand off only a strictly validated `upi://pay` request.
- Let optional AI return only validated context; backend deterministic policy alone sets signals, score, and verdict.
- Explain every score contribution and map only 0-29 to SAFE, 30-69 to CAUTION, and 70-100 to HIGH RISK.
- Require explicit user action and an extra warning for caution/high-risk external handoff.
- Never claim payment interception, blocking, reversal, reporting, or bank/NPCI/government access.
- Do not log or commit secrets, screenshots, credentials, or complete payment input.

## Required gates

| Surface | Gate |
|---|---|
| Backend | Ruff, full pytest, focused regression tests, live Uvicorn HTTP integration, strict validation/error-envelope checks |
| Flutter | `flutter analyze`, `flutter test`, release Web build, release APK when the local Android toolchain permits |
| Web | Running backend and release-like Flutter Web app; Chromium at 375, 768, and 1440 px; SAFE/CAUTION/HIGH, malformed, loading, offline, and server-error flows; keyboard/focus; console and failed-request inspection |
| Security | Secret scan, dependency health/audit where tooling is available, authentication/session regressions, independent source review |
| Release | SQLite/migration boundary documented, signing requirements documented, deployment assets syntax-checked |

Use `scripts/verify.ps1` for repeatable static/unit/build gates. Run live API and browser gates separately and preserve their exact commands and screenshot paths. A conditional gate is `blocked`, not `passed`, when its toolchain or emulator is unavailable.
