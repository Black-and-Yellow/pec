# FinGuard

**Detect risk. Trigger response.**

FinGuard is a pre-payment safety layer for UPI QR codes and payment links. It parses a request before handoff, produces a deterministic and explainable risk score, and makes the safest next action obvious. It never claims to freeze, reverse, cancel, or intercept a transaction inside a bank or third-party UPI app.

The safety flow stays deliberately focused:

```text
SCAN OR PASTE -> SCORE EXPLAINABLY -> RESPOND WITH USER CONFIRMATION
```

## What is implemented

- One Flutter codebase for Android and responsive Web.
- A responsive welcome experience with email/password accounts, Google OpenID Connect, secure rotating sessions, guest mode, sign-out, and self-service account deletion.
- Live QR scanning on supported devices, QR-image upload, and UPI-link paste.
- Strict parsing of standard `upi://pay` requests; arbitrary scanned URLs are rejected.
- FastAPI, SQLAlchemy 2, SQLite, and typed JSON contracts.
- A deterministic 0-100 risk engine with centralized weights and thresholds.
- Visible evidence for every score contribution.
- SAFE, CAUTION, and HIGH RISK paths with deliberate confirmation before risky handoff.
- A guided 90-second offline Risk Lab with an outcome spectrum for comparing four deterministic judge cases, including a legitimate open-amount static QR, without API, AI, or payment-app access.
- A three-step independent-verification checklist before any live CAUTION or HIGH RISK handoff can continue.
- A cooling-off pause before a live HIGH RISK handoff can continue after its checklist, scaled by the payee's trust grade and never shorter than five seconds.
- An on-device trusted contact and Android text/plain share-target intake for messages or UPI requests.
- An immediate deterministic plain-language score summary with optional, separately labelled, consent-gated Gemini wording that cannot alter or replace the assessment summary.
- Protective actions, an "already paid" recovery flow, incident draft copy, the official Indian cybercrime route, and native trusted-contact sharing.
- Optional Gemini text/image context extraction with explicit consent, strict structured output, and local-rule fallback.
- An identifier checker that takes a `upi://pay` link, a bare UPI ID, or an Indian mobile number, works out which it is, and reports what FinGuard has observed. A mobile number is expanded into the phone-shaped UPI addresses it could correspond to; FinGuard cannot identify a number's owner or the account behind it.
- A payee trust report built from address structure plus FinGuard's own check history, with a provenance label on every pillar (read on this device, FinGuard checks, user-reported, seeded demo).
- Collection-account pattern detection, reported as check-pattern evidence rather than transaction evidence. It complements bank-side systems such as RBIH MuleHunter; it does not replicate them and has no access to transaction data.
- An Intent Shield: an optional pre-analysis question about what the user expects, compared against what the request actually does. It never contributes to the risk score.
- A published, versioned Policy Card at `GET /api/v1/policy/card` giving every weight, its plain-language reason, its source category, the band boundaries, and the limitations. The app renders it and never keeps its own copy of the weights.
- Anonymous local check history and clearly labelled seeded demo history/reputation data.
- Backend tests, Flutter tests, CI, and a native low-memory OCI deployment using Nginx, systemd, and Let's Encrypt.

## What FinGuard is, and is not

FinGuard is a consumer-side pre-authorization safety layer. It reads a payment
request before a UPI app is opened, explains what it can see, and asks the
person to confirm. It sits beside bank-side systems rather than duplicating
them: institutions such as RBIH MuleHunter act on transaction data FinGuard has
no access to, and the two see different things about the same fraud.

It does not have, and never claims:

- Any connection to a bank, NPCI, or a government reporting system.
- The ability to block, reverse, freeze, or report a transaction.
- Visibility of any payment. Reputation counts *safety checks* run by FinGuard
  users, not money moving.
- Identification of a phone number's owner or the account behind it.
- A statistically trained fraud model. Scores are deterministic intervention
  values, not probabilities. See `GET /api/v1/policy/card`.

Where the app links to the national cybercrime portal, it copies the address
and opens the official page. It never submits anything on the user's behalf.

### Data provenance

Every piece of evidence is labelled with where it came from:

| Label | Meaning |
|---|---|
| Read on this device | Computed from the request itself; no lookup, reproducible offline |
| FinGuard checks | Counted from safety checks run by FinGuard users; not bank data |
| User-reported | One person's unverified claim, made by preparing an incident report |
| Seeded demo data | Fixture rows shipped to make the demo legible; not observations |

**Preparing an incident draft publishes nothing about anybody.** Reading what a
report would say is not consent to file one, so no caller - signed in or not -
can change what other users see about a third party. Publishing would belong to
a submission endpoint that does not exist yet, and would need verified
identity, an explicit opt-in, confirmation the payment happened, one report per
person per address, rate limiting and moderation.

Community standing may raise concern about an unusual amount and is never
allowed to reduce one below its baseline. Reputation is keyed on a
client-supplied device identifier that can be manipulated, so a path where good
standing quietens a signal is a path where a manufactured reputation buys
silence.


## Architecture

```text
Flutter Android / Web
        |
        | HTTPS JSON
        v
FastAPI modular monolith
  |-- account and OAuth session service
  |-- strict UPI parser
  |-- deterministic risk engine
  |-- optional Gemini context adapter
  |-- response / evidence builder
  `-- repositories -> SQLite
```

Gemini may extract bounded context flags and, after explicit consent, select optional ancillary wording for an already-final stored assessment. The selectable explanations are server-owned sentences in a dynamic schema enum, and the backend independently requires an exact allowlist match, so arbitrary provider prose is never displayed. Gemini never sets the final score, verdict, signals, or recommended action. The deterministic service consumes any validated flags, applies the same centralized policy every time, renders its own explanation first, and continues normally when Gemini is absent, malformed, or over quota.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for contracts, scoring, data flow, and trust boundaries.

## Repository

```text
backend/       FastAPI application, fixtures, and pytest suite
frontend/      Flutter Android/Web client and widget/unit tests
deploy/        OCI setup, systemd, Nginx, Certbot, and release scripts
.github/       CI and SSH deployment workflows
docs/          Architecture documentation
FinGuard.pdf   Original PEC Hacks submission; preserved unchanged
```

## Prerequisites

- Python 3.12 (3.11 or newer is supported by the package metadata)
- Flutter stable with Dart 3.10 or newer
- Android Studio/SDK for an Android build, or Chrome/Edge for Web
- Git

Docker, WSL, a paid database, and an AI key are not required.

## Local development on Windows

### 1. Backend

From `E:\Projects\PEC` in PowerShell:

```powershell
Copy-Item .env.example .env
cd backend
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip==26.2.1
.\.venv\Scripts\python.exe -m pip install --constraint constraints-production.txt -e ".[dev]"
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload
```

The app reads `backend/.env` first and then the repository-root `.env` without overriding variables already set in the shell. On startup it creates the SQLite schema and idempotently loads the labelled demo fixtures. The API is available at `http://127.0.0.1:8000`, with interactive documentation at `/docs` and health at `/api/v1/health`.

### 2. Flutter Web

In a second PowerShell window:

```powershell
cd frontend
flutter pub get
flutter run -d chrome --web-port 8080 --dart-define=API_BASE_URL=http://127.0.0.1:8000/
```

The production Web build uses the current page origin by default so Nginx can serve `/` and proxy `/api/` without embedding a host or secret. Add `--dart-define=GOOGLE_WEB_CLIENT_ID=...apps.googleusercontent.com` when Google sign-in is configured.

### 3. Android

Start the backend, then:

```powershell
cd frontend
flutter devices
flutter run -d <device-id>
```

The Android emulator default is `http://10.0.2.2:8000/`. For a physical phone, bind the development API to the LAN and pass its reachable address:

```powershell
# backend terminal - trusted development network only
.\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000

# frontend terminal
flutter run -d <device-id> --dart-define=API_BASE_URL=http://192.168.1.10:8000/
```

The debug Android manifest permits local HTTP development. The release manifest requires HTTPS, and the Gradle release gate requires an explicit HTTPS `API_BASE_URL`. A release build also fails unless all four `FINGUARD_KEYSTORE_PATH`, `FINGUARD_KEYSTORE_PASSWORD`, `FINGUARD_KEY_ALIAS`, and `FINGUARD_KEY_PASSWORD` values are present. CI may set `FINGUARD_ALLOW_DEMO_RELEASE=true` to compile a clearly non-distributable, debug-signed artifact; never publish that artifact.

## Configuration

| Variable | Required | Purpose |
|---|---:|---|
| `APP_ENV` | No | `development`, `test`, or `production` |
| `LOG_LEVEL` | No | Structured backend log level, normally `INFO` |
| `DATABASE_URL` | No | SQLite URL; production uses `/var/lib/finguard/finguard.db` |
| `ALLOWED_ORIGINS` | Production | Comma-separated Flutter Web origins; production accepts HTTPS origins only, while local HTTP remains development/test-only |
| `ENABLE_AI_CONTEXT` | No | Defaults to `false`; explicit switch for optional Gemini analysis |
| `GEMINI_API_KEY` | AI enablement | Server-only Gemini Developer API key; required when `ENABLE_AI_CONTEXT=true` |
| `GEMINI_MODEL` | No | Defaults to stable `gemini-2.5-flash-lite` |
| `GEMINI_TIMEOUT_SECONDS` | No | Short timeout before deterministic fallback |
| `MAX_SCREENSHOT_BYTES` | No | Decoded screenshot limit; defaults to 2 MB |
| `ASSESSMENT_RETENTION_DAYS` | No | Days to retain scored request records; defaults to 30 |
| `MAX_ASSESSED_RECORDS_PER_DEVICE` | No | Oldest-record cap per anonymous device; defaults to 50 |
| `MAX_ASSESSED_RECORDS_TOTAL` | No | Whole-service assessed-record cap; defaults to 5,000 |
| `AUTH_SECRET_KEY` | Production | Unique random secret of at least 32 characters used to sign short-lived access and context-integrity tokens; production rejects documented placeholders |
| `ACCESS_TOKEN_MINUTES` | No | Access-token lifetime from 5-60 minutes; defaults to 15 |
| `REFRESH_TOKEN_DAYS` | No | Rotating session lifetime from 1-90 days; defaults to 30 |
| `MAX_REGISTERED_USERS` | No | Single-node account ceiling from 1-100,000; defaults to 5,000 |
| `GOOGLE_OAUTH_CLIENT_IDS` | Google OAuth | Comma-separated Web/Android OAuth client IDs accepted by the backend |

`API_BASE_URL` is a Flutter compile-time public endpoint, not a secret. Never put `GEMINI_API_KEY` or an SSH key in `--dart-define`.

### Credentials needed

The complete local demo needs **no API key**. AI is disabled by default. If optional AI context extraction is deliberately enabled, put both settings in the untracked root `.env` for development or `/etc/finguard/finguard.env` in production:

```dotenv
ENABLE_AI_CONTEXT=true
GEMINI_API_KEY=replace_with_your_key
```

The included Nginx configuration applies a stricter per-IP limit to the context
endpoint. That limit only bounds abuse and provider cost on the documented
single-node target; it is not user identity, a distributed quota, or billing
assurance. Public AI enablement still requires a monitored hard provider budget
or authenticated gateway quota. The deterministic parser, local context rules,
signed context handoff, and risk score continue to work with AI disabled.

Native QR scanning, SQLite, incident drafting, clipboard copy, native share, the UPI handoff, and the official reporting link need no API keys. FCM is intentionally not part of this MVP.

Email/password and guest access need no external identity service. To enable Google sign-in, create OAuth 2.0 clients in Google Cloud for the deployed Web origin and Android package/signing certificate. Put every accepted client ID in the server-side `GOOGLE_OAUTH_CLIENT_IDS`; pass the Web client ID as `GOOGLE_WEB_CLIENT_ID` and the Web/server client ID used by Android as `GOOGLE_ANDROID_SERVER_CLIENT_ID` at Flutter build time. OAuth client IDs are public identifiers, while `AUTH_SECRET_KEY` remains server-only. Google sign-in stays hidden when either side is not configured, so a partial configuration cannot produce a broken button.

The documented single-process, one-worker service admits at most 5,000 account rows
by default. A process-local admission lock serializes the account count, password
hash, and insert, while releasing the SQLite read transaction before hashing so
unrelated risk and auth writes remain available. First-time Google accounts obey the
same admission lock and ceiling. Google identities are bound only by their verified
subject: an unknown subject colliding with any existing email fails closed instead
of silently linking accounts. A future linking flow must require an already
authenticated FinGuard account. Reaching the ceiling returns a generic
temporary-unavailability response and requires an operator to deliberately raise
`MAX_REGISTERED_USERS`. The included Nginx configuration also rate-limits public
auth routes per IP. These process-local controls are not a distributed identity or
abuse quota; multiple API workers remain unsupported until account admission moves
to shared transactional storage and upstream global abuse protection is in place.

OCI deployment uses SSH credentials rather than application API keys; see the deployment section below.

## API

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/v1/health` | Database and optional-AI configuration health |
| `GET` | `/api/v1/auth/capabilities` | Advertise enabled account providers |
| `POST` | `/api/v1/auth/register` | Create an email/password account and session |
| `POST` | `/api/v1/auth/login` | Start an email/password session |
| `POST` | `/api/v1/auth/google` | Exchange a verified Google ID token for a FinGuard session |
| `POST` | `/api/v1/auth/refresh` | Rotate an opaque refresh token and issue a short-lived access token |
| `POST` | `/api/v1/auth/logout` | Revoke a refresh session |
| `GET` | `/api/v1/auth/me` | Read the authenticated FinGuard profile |
| `POST` | `/api/v1/auth/account/delete` | Permanently delete the authenticated identity and all sessions |
| `POST` | `/api/v1/payments/parse` | Validate and canonicalize a `upi://pay` URI |
| `POST` | `/api/v1/risk/score` | Persist an explainable deterministic assessment |
| `POST` | `/api/v1/risk/explain` | Explain a stored final assessment; deterministic template with optional consent-gated wording |
| `POST` | `/api/v1/context/analyze` | Optional consent-gated context extraction with fallback |
| `POST` | `/api/v1/response/prepare` | Prepare prevention/recovery evidence and actions |
| `GET` | `/api/v1/history` | Assessment history for the `X-FinGuard-Device-ID` capability header |
| `POST` | `/api/v1/trust/lookup` | Read one payee's standing without scoring a payment |
| `POST` | `/api/v1/trust/check` | Check a link, a bare UPI ID, or an Indian mobile number |
| `GET` | `/api/v1/policy/card` | Publish the scoring policy: weights, reasons, bands, limitations |
| `GET` | `/api/v1/demo/scenarios` | Stable labelled demo inputs and expected results |

All request models reject unknown fields. Validation errors are actionable and do not echo uploaded content. Screenshots are size/type/signature checked, are not logged, and are not stored. Risk scoring requires an explicit validated anonymous `device_id`; the public API never silently assigns the shared demo identity.

The service stores scored payment requests under a domain-separated SHA-256 representation of the anonymous device identifier, separate from the optional account identity, so it can protect response preparation from client-side tampering and provide assessment history without attaching payment facts to a login. The history capability is carried in a dedicated header rather than a logged URL. During the bounded retention window, reads also match an exact validated pre-hash identifier so an upgrade does not hide still-valid history; there is no bulk identifier migration.

Every scoring transaction deletes expired `ASSESSED` records and prunes the oldest assessed records to `MAX_ASSESSED_RECORDS_PER_DEVICE` and `MAX_ASSESSED_RECORDS_TOTAL` before adding the new record. The defaults are 50 per anonymous device and 5,000 total for the documented one-worker SQLite service. Seeded `COMPLETED` demo history is excluded from expiry and capacity pruning. Startup and ongoing register, login, Google, refresh, logout, and account-deletion operations each remove at most 100 expired or old-revoked refresh sessions, bounding cleanup work per request. At most five active refresh sessions are retained per account; issuing another invalidates the oldest active token. Clearing Flutter history removes the on-device copy only. Account deletion removes the account and its server sessions, while anonymous assessment retention remains governed by the retention policy.

## Deterministic demos

| Scenario | Evidence | Expected result |
|---|---|---:|
| Coffee-shop QR, known payee, INR 180 | Existing seeded device pattern | `SAFE 0/100` |
| Tea-stall sticker QR, first-time payee, amount entered later | First-time recipient + lightly weighted open amount | `SAFE 23/100` |
| Marketplace seller, first-time payee, INR 4,500 | First-time recipient + unusual amount | `CAUTION 33/100` |
| Fake KYC request, seeded VPA, INR 25,000 | Seed match + relationships + amount + KYC/urgency | `HIGH RISK 99/100` |

The Flutter client includes matching bundled fixtures so all four judge cases remain usable if the network or Gemini is unavailable. Its guided Risk Lab moves through SAFE, CAUTION, and HIGH RISK on a selectable outcome spectrum, compares payment facts, scores, and evidence, then opens only a view-only demo result with payment, report, share, and already-paid actions suppressed. Seeded data is always labelled as demo data and is never presented as live bank, NPCI, or national fraud intelligence.

## Verification

Backend:

```powershell
cd backend
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m mypy app
.\.venv\Scripts\python.exe -m pytest -p no:cacheprovider --cov=app --cov-branch --cov-report=term-missing
```

Flutter:

```powershell
cd frontend
flutter analyze
flutter test
flutter build web --release
flutter build apk --release --dart-define=API_BASE_URL=https://api.example.dev/
```

The Android command requires the operator-controlled signing environment variables above. For local compile evidence only, `scripts/verify.ps1` uses the explicit non-distributable demo override and `https://example.invalid/`. CI runs dependency audit, static typing, lint, coverage-gated tests, Flutter analysis/tests, and release Web and Android compile checks on every push and pull request.

## SQLite schema evolution

Production startup may create the initial schema, but it is not a migration engine. Before any model change, take an application-consistent copy of the database and its WAL/SHM companions while the service is stopped, rehearse a versioned forward migration against that copy, and verify both application startup and rollback. Additive columns still need an explicit migration; never rely on `create_all()` to alter existing tables. Keep the prior release and backup until health, parse, score, history, and authentication smoke checks pass. A move to multiple API workers or nodes requires a planned migration to shared transactional storage rather than attempting to share this SQLite file.

## OCI Always Free deployment

The production target is an Ubuntu 24.04 amd64 OCI `VM.Standard.E2.1.Micro`
using one Uvicorn worker behind Nginx:

```text
/opt/finguard/backend/       API source and virtual environment
/opt/finguard/web/           Flutter Web build
/var/lib/finguard/           SQLite state
/etc/finguard/finguard.env   root-managed server configuration/secrets
/etc/finguard/release_allowed_signers  root-managed release public key
```

Follow [deploy/README.md](deploy/README.md) for one-time host setup, DNS, free Let's Encrypt issuance, renewal verification, service checks, and rollback-safe release activation.

GitHub deployment requires these repository or `production` environment secrets:

- `OCI_HOST`: VM public hostname or IPv4 address.
- `OCI_USER`: SSH account, normally `ubuntu`.
- `OCI_SSH_KEY`: complete unencrypted private deployment key.
- `RELEASE_SIGNING_KEY`: complete unencrypted private Ed25519 signing key,
  dedicated to releases and distinct from `OCI_SSH_KEY`.
- `OCI_KNOWN_HOSTS`: verified OpenSSH known-hosts line(s) for the VM.
- `DEPLOY_PATH`: absolute writable staging path, such as `/home/ubuntu/finguard-deploy`.
- `OCI_PORT`: optional; defaults to `22`.

It also accepts the public repository/environment variable `GOOGLE_WEB_CLIENT_ID` for the Web build. Production server configuration must provide a unique `AUTH_SECRET_KEY` and the matching `GOOGLE_OAUTH_CLIENT_IDS`. The host must contain only the matching public release key as principal `finguard-ci` in the root-owned, mode `0600` `/etc/finguard/release_allowed_signers`; the runner verifies namespace `finguard-release` before inspecting the uploaded archive.

Keep `GEMINI_API_KEY` on the server, not in GitHub Actions. Certbot asks for a certificate email address during setup but no API key and no paid certificate.

## Zero-cost design

- SQLite has no hosted database cost.
- The core parser, score, report builder, and demo fixtures work offline from paid services.
- Gemini is optional, disabled by default, and degrades to local deterministic analysis when unavailable; public enablement requires monitored provider-side budget controls.
- Native share replaces paid SMS/email providers.
- OCI Always Free is the intended host; Nginx, systemd, and Let's Encrypt are free.
- No automatic paid upgrade or billing-dependent integration exists.

## Operational boundaries

- A SAFE result means no configured warning signal was found; it is not a guarantee that a recipient is legitimate.
- FinGuard checks a request before handoff. It cannot observe what the user later approves in a UPI app.
- A live CAUTION or HIGH RISK handoff stays disabled until the user acknowledges three independent checks, and still requires the existing warning confirmation; those acknowledgements are not proof that a recipient is legitimate.
- A live HIGH RISK handoff also enforces a ten-second cooling-off pause after the three checks; the separate warning confirmation still follows.
- It has no bank-internal, NPCI-internal, VPA-age, transaction-reversal, or government-report-submission access.
- Recipient reputation and relationship counts are clearly labelled seeded hackathon fixtures.
- Incident drafts and share messages remain on screen until the user explicitly copies, opens, or sends them.
- The optional trusted-contact name and phone number are stored only on the device and are never sent to the FinGuard API. WhatsApp, SMS, dialer, and native-share actions all remain user-confirmed OS handoffs.
- Plain-language summaries are display-only derivatives of a stored final assessment. Gemini may add separately labelled ancillary wording after consent, but it never replaces the deterministic summary; neither form can set or change score, verdict, signals, or recommended action.
- Account sessions are production-hardened for this single-node deployment, but email verification and password recovery require choosing and configuring a transactional email provider before a public launch.
- SQLite and one API worker are intentional for the included zero-cost OCI deployment. Horizontal scale requires a versioned migration to managed PostgreSQL/shared persistence and should be completed before traffic exceeds a single-node workload.
- Store-distributed Android releases require a private Play signing key, package registration, and a Google OAuth Android client bound to the final signing certificate.
