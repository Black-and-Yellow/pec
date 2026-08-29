# FinGuard project context

## Project overview

FinGuard is a pre-payment safety layer for Indian UPI payment requests. It accepts only standard `upi://pay` QR/link data, evaluates it before a payment-app handoff, and presents an explainable deterministic risk result: SAFE, CAUTION, or HIGH RISK. It does not execute, freeze, cancel, reverse, observe, or report a payment.

## Problem statement and target users

The project addresses social-engineering and scam risk around QR codes, payment links, suspicious messages, unfamiliar payees, and unusually large UPI requests. It is intended for people about to make a UPI payment, including users who prefer an account-free private/guest flow. Optional accounts provide a FinGuard identity and sessions; payment checks are tied instead to an anonymous device capability.

## Core features

- Camera QR scanning, QR-image decoding/upload, and pasted UPI-link intake.
- Strict parsing and canonicalization of `upi://pay` requests; arbitrary URLs, malformed encodings, duplicate fields, unsupported currencies, invalid VPAs, and invalid amounts are rejected.
- Backend-only deterministic, explainable 0--100 risk score and SAFE (0--29), CAUTION (30--69), HIGH (70--100) verdict mapping.
- Evidence rows for every contributing signal. Current policy covers seeded demo-recipient matches, first-time payees, missing/unusual amounts, suspicious notes, seeded identifier relationships, and validated message-context flags.
- Optional, consent-gated Gemini context extraction for bounded boolean signals only. Local text rules and the payment-risk path remain usable when Gemini is disabled or unavailable.
- Explicit confirmations for UPI app handoff, sharing, clipboard copy, report preparation, and opening the official cybercrime site. CAUTION/HIGH live handoff also requires three independent-verification acknowledgements.
- HIGH RISK live handoff adds a ten-second cooling-off pause after the verification checklist.
- A deterministic plain-language assessment summary appears immediately; an optional consent-gated Gemini rewrite is display-only and cannot change the final policy result.
- High-risk prevention/recovery drafts, a first-hour recovery clock, confirmed 1930 dialer handoff, local fallback drafts, cybercrime.gov.in opening, and native sharing. FinGuard never submits a complaint itself.
- An optional trusted contact is stored only on the device and can be reached through confirmed WhatsApp, SMS, or native-share handoffs.
- Android accepts shared text/plain messages and UPI requests through the OS share target and routes them through the existing validation flows.
- Email/password accounts, optional Google OIDC login, guest mode, rotating sessions, sign-out, and account deletion.
- Local check history plus separately labelled seeded demos and a view-only offline Risk Lab. Demo/history results cannot initiate UPI handoff.

## Tech stack

| Layer | Implementation |
|---|---|
| Client | Flutter/Dart single codebase for Android and responsive Web |
| Backend | FastAPI, Pydantic v2, SQLAlchemy 2, Uvicorn |
| Persistence | Local SQLite (single-node, one-worker target) |
| Authentication | Argon2 via `pwdlib`, HS256 access tokens, hashed opaque rotating refresh tokens, optional Google ID-token verification |
| Optional AI | Gemini Developer API through `httpx`, schema-bound JSON output |
| Device integrations | `mobile_scanner`, `image_picker`, ZXing/image decoding, platform URI launch, share sheet, clipboard |
| Quality/automation | pytest/coverage, Ruff, mypy, Flutter tests/analyzer, Playwright, GitHub Actions |
| Production runtime | OCI Ubuntu VM, Nginx, systemd, one loopback Uvicorn worker, Let's Encrypt |

## Architecture and data flow

```text
Flutter Android/Web
  -> local UPI validation
  -> FastAPI /api/v1/payments/parse -> canonical request
  -> FastAPI /api/v1/risk/score -> RiskEngine + repositories -> SQLite
  -> explainable score/result -> immediate local summary
  -> optional FastAPI /api/v1/risk/explain -> stored assessment -> display prose only
  -> local history + explicit user choice
  -> (only after explicit confirmation) UPI app, share sheet, clipboard, or browser

Optional message/image context:
Flutter -> /api/v1/context/analyze -> local rules or Gemini -> strict ContextSignals
        -> short-lived signed integrity token -> /api/v1/risk/score
```

The FastAPI app is a modular monolith. Routes use strict Pydantic schemas, services hold domain logic, repositories isolate SQLAlchemy access, and the SQLite database is initialized and seeded at startup. Nginx serves the Flutter Web build and proxies `/api/` to a one-worker API bound to `127.0.0.1:8000`.

### Deterministic scoring authority

`backend/app/risk_policy.py` centralizes weights and thresholds. `RiskEngine` is the sole scorer/verdict mapper: it sums applicable signal weights, caps the total at 100, and maps the configured ranges. Gemini may return strict `ContextSignals` or select optional ancillary wording from a schema-bound list of server-owned sentences derived from an already-final stored assessment; arbitrary provider prose is rejected, and it cannot set recipient reputation, score, signals, recommendation, or verdict. The client independently rejects risk responses when their score differs from signal-weight total or their level is inconsistent with the fixed ranges.

### Privacy and trust boundaries

- Payment data, QR/image data, OAuth tokens, APIs, and Gemini output are treated as untrusted input.
- Context screenshots are type/signature/size checked, used in memory, not persisted, and are excluded from request logging. Gemini is called only if server configuration and explicit user consent are both present.
- API request models forbid unknown fields; error responses do not echo uploaded content.
- Scored payment rows retain a domain-separated SHA-256 device identifier. Account identity intentionally has no foreign key to payment assessments.
- Assessed rows have configurable retention and per-device/global caps. Seeded `COMPLETED` demo history is preserved separately so it can represent prior local payment patterns without claiming a scored request was paid.
- Logs record request metadata (method/path/status/duration/random ID), not payment payload or screenshot data.

## Main business flows

### Live pre-payment check

1. A user chooses guest/account access, then scans a QR, selects a QR image, or pastes a UPI URI.
2. Flutter validates the URI before calling the API. The API parses it again and returns a canonical `upi://pay` URI; the client verifies every semantic field matches the original request.
3. Flutter obtains its anonymous device ID and requests `/risk/score`. The backend checks completed-payment patterns, seeded demo indicators, optional signed context, and the deterministic policy; it stores the assessment and signals.
4. Flutter verifies the returned risk envelope, stores a compact local history record when possible, and displays payment facts, score, evidence, recommended action, and an immediate deterministic plain-language summary. With explicit consent, a live stored assessment may request separately labelled ancillary wording from `/risk/explain`; it never replaces the deterministic summary, and seeded demos never request it.
5. SAFE handoff still needs an explicit confirmation. CAUTION requires the three checklist acknowledgements plus a warning confirmation. HIGH RISK additionally requires a ten-second cooling-off pause after the checklist. Only then does the client ask the operating system to open the validated UPI URI.

### Suspicious-message context

1. The user pastes a message and/or selects an image (the app does not save the screenshot).
2. The user may opt in to Gemini. Without consent/configuration/provider availability, local text rules provide fallback context.
3. The backend returns strict context flags and, where applicable, a five-minute signed integrity token.
4. A subsequent live payment check forwards context only when the matching token is present and valid.

### High-risk/recovery actions

1. A high-risk result can show verification guidance, prepare a private draft, message an on-device trusted contact after confirmation, share a fallback message, or start an already-paid recovery draft.
2. Report preparation validates the stored assessment/payment match on the server; the client uses a deterministic local draft if that request is unavailable. Seeded demos always use local view-only drafting.
3. The already-paid path asks roughly when payment occurred, shows a first-hour countdown or continued-reporting encouragement, and offers a confirmed `tel:1930` dialer handoff without promising recovery.
4. Copying the draft, messaging/sharing, opening the dialer, and opening `cybercrime.gov.in` each require a confirmation. The user, not FinGuard, performs every external action or submission.

### Account/session flow

1. Email/password registration/login or verified Google ID-token login creates an access token and opaque refresh token.
2. Access tokens are held in client memory; refresh tokens use platform secure storage. Refresh consumes/revokes the prior refresh token, creates a replacement, and each account retains at most five active sessions.
3. Account deletion requires `DELETE` and, for password accounts, the password; it removes the account and its sessions. Anonymous payment-history retention remains independent.

## Main HTTP APIs

| Endpoint | Purpose |
|---|---|
| `GET /api/v1/health` | Database/API health and optional-AI status |
| `GET /api/v1/auth/capabilities` | Advertises configured identity providers |
| `POST /api/v1/auth/register`, `/login`, `/google` | Starts password or Google session |
| `POST /api/v1/auth/refresh`, `/logout` | Rotates or revokes refresh session |
| `GET /api/v1/auth/me`, `POST /auth/account/delete` | Authenticated profile and deletion |
| `POST /api/v1/payments/parse` | Strict URI parse and canonical payment response |
| `POST /api/v1/risk/score` | Persists deterministic assessment for explicit device ID |
| `POST /api/v1/risk/explain` | Returns deterministic or consent-gated display wording from a stored final assessment |
| `POST /api/v1/context/analyze` | Consent-gated local/Gemini context signal extraction |
| `POST /api/v1/response/prepare` | Creates prevention/recovery response from matching stored assessment |
| `GET /api/v1/history` | Recent retained assessments for `X-FinGuard-Device-ID` |
| `GET /api/v1/demo/scenarios` | Labelled, stable demo scenarios (with signed demo context when present) |

## Database models

- `User`: optional FinGuard identity; email/password hash or Google subject.
- `RefreshSession`: hashed refresh token, expiry, revocation time, user relation.
- `Transaction`: payment facts, hashed device key, source, and status.
- `RiskAssessment`: one score/verdict/recommendation per transaction.
- `RiskSignalRecord`: ordered explainable signal contributions.
- `FraudIndicator`: clearly labelled seeded demo indicator/relation data.

## External integrations

- Gemini Developer API is optional and disabled by default. After explicit consent it may receive user-selected text/image for strict context signals or bounded fields from a stored final assessment for display-only explanation wording; deterministic local fallbacks cover both paths.
- Google OIDC is optional: backend verifies Google ID tokens whose audience is in `GOOGLE_OAUTH_CLIENT_IDS`; the Flutter sign-in UI is hidden until compatible configuration exists.
- Android/Web OS APIs handle camera/image selection, UPI URI launch, browser launch, share, and clipboard. These are handoffs, not payment/reporting integrations.
- OCI/Nginx/systemd/Let's Encrypt provide an optional deployment target; GitHub Actions creates signed releases and a restricted SSH transport activates them.

## Important folders and files

| Location | Purpose |
|---|---|
| `README.md` | Product boundary, local setup, API/configuration, demos, operational limitations |
| `docs/ARCHITECTURE.md` | Architecture, risk policy, trust boundaries, deployment/scaling assumptions |
| `backend/app/main.py` | App factory, lifespan/schema/seed cleanup, CORS, logging, error envelopes, routers |
| `backend/app/schemas.py` and `auth_schemas.py` | Strict public API/data contracts |
| `backend/app/services/upi_parser.py` | UPI URI acceptance and validation |
| `backend/app/risk_policy.py`, `services/risk_engine.py` | Central weights/thresholds and deterministic scoring |
| `backend/app/services/explanation_service.py` | Deterministic explanation template and schema-bound, server-owned optional Gemini selection boundary |
| `backend/app/api/routes/` | Public FastAPI endpoint implementations |
| `backend/app/services/context_analyzer.py`, `context_integrity.py`, `integrations/gemini_client.py` | Optional AI/local context boundary and signed handoff proof |
| `backend/app/services/auth_service.py`, `repositories/user_repository.py` | Password/Google authentication and rotating sessions |
| `backend/app/db/models.py`, `repositories/transaction_repository.py`, `db/seed.py` | SQLite entities, retention/history, and labelled demo seed data |
| `frontend/lib/app.dart`, `services/app_services.dart` | Flutter composition/dependency wiring |
| `frontend/lib/models/payment.dart`, `risk.dart` | Client validation and fail-closed API-response checks |
| `frontend/lib/models/risk_explanation.dart`, `services/report_builder.dart` | Strict explanation response and offline deterministic wording mirror |
| `frontend/lib/services/api_service.dart`, `auth_api.dart` | Backend clients |
| `frontend/lib/screens/` | Onboarding, intake, consent, results, history, account/privacy, recovery, and Risk Lab UI flows |
| `frontend/lib/services/external_actions.dart` | OS-level UPI/browser/share/clipboard handoffs |
| `frontend/lib/services/share_intake.dart`, `android/.../MainActivity.kt` | Android text/plain share-target intake and bounded Flutter handoff |
| `frontend/lib/services/local_store.dart`, `auth_store.dart` | Anonymous device/history storage and secure refresh-token storage |
| `frontend/android/app/build.gradle.kts` | Android HTTPS/release-signing fail-closed gate |
| `deploy/` | OCI setup, Nginx, systemd, HTTPS, signed release, and restricted SSH deployment assets |
| `.github/workflows/ci.yml`, `deploy.yml` | Verification/build pipeline and signed main-branch deployment workflow |
| `scripts/verify.ps1` | Repeatable secret scan, backend, Flutter, Web, and non-distributable Android verification |
| `backend/tests/`, `frontend/test/`, `frontend/e2e/` | Unit/integration and real-stack browser coverage |

## Important technical decisions and limits

- A missing amount contributes 5 points when no corroborating warning exists and 20 when another seeded, note, relationship, or validated context warning fires; first-time payee deliberately does not count as corroboration.
- Trusted-contact details never cross the API boundary. The client stores them locally and opens only confirmed OS messaging/dialer/share intents.
- SQLite plus one Uvicorn worker is an intentional zero-cost, single-node deployment boundary. Scaling requires shared transactional persistence and versioned migrations; `create_all()` is not a production migration system.
- No paid service is needed for the core scanner/parser/scorer/demos. Gemini and Google login are optional.
- Demo indicators/history are explicitly seeded hackathon data; they are not live bank, NPCI, government, or national fraud intelligence.
- A SAFE result means the configured signals did not fire, not that the payee is legitimate.
- Android production distribution requires an operator-provided keystore and HTTPS API origin. The explicit demo release is debug-signed and non-distributable.
- Email verification and password recovery are intentionally deferred until a transactional email provider is selected.
