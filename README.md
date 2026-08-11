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
- Protective actions, an "already paid" recovery flow, incident draft copy, the official Indian cybercrime route, and native trusted-contact sharing.
- Optional Gemini text/image context extraction with explicit consent, strict structured output, and local-rule fallback.
- Anonymous local check history and clearly labelled seeded demo history/reputation data.
- Backend tests, Flutter tests, CI, and a native low-memory OCI deployment using Nginx, systemd, and Let's Encrypt.

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

Gemini extracts bounded context flags only. It never sets the final score or verdict. The deterministic service consumes any validated flags, applies the same centralized policy every time, and continues normally when Gemini is absent or over quota.

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
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"
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

The debug Android manifest permits local HTTP development. The release manifest requires HTTPS. The included release signing is suitable for a hackathon demo build; configure a private release keystore before Play Store distribution.

## Configuration

| Variable | Required | Purpose |
|---|---:|---|
| `APP_ENV` | No | `development`, `test`, or `production` |
| `LOG_LEVEL` | No | Structured backend log level, normally `INFO` |
| `DATABASE_URL` | No | SQLite URL; production uses `/var/lib/finguard/finguard.db` |
| `ALLOWED_ORIGINS` | Production | Comma-separated Flutter Web origins; wildcard is rejected in production |
| `ENABLE_AI_CONTEXT` | No | Explicit switch for optional Gemini analysis |
| `GEMINI_API_KEY` | No | Server-only Gemini Developer API key |
| `GEMINI_MODEL` | No | Defaults to stable `gemini-2.5-flash-lite` |
| `GEMINI_TIMEOUT_SECONDS` | No | Short timeout before deterministic fallback |
| `MAX_SCREENSHOT_BYTES` | No | Decoded screenshot limit; defaults to 2 MB |
| `ASSESSMENT_RETENTION_DAYS` | No | Days to retain scored request records; defaults to 30 |
| `AUTH_SECRET_KEY` | Production | Random secret of at least 32 characters used to sign short-lived FinGuard access tokens |
| `ACCESS_TOKEN_MINUTES` | No | Access-token lifetime from 5-60 minutes; defaults to 15 |
| `REFRESH_TOKEN_DAYS` | No | Rotating session lifetime from 1-90 days; defaults to 30 |
| `GOOGLE_OAUTH_CLIENT_IDS` | Google OAuth | Comma-separated Web/Android OAuth client IDs accepted by the backend |

`API_BASE_URL` is a Flutter compile-time public endpoint, not a secret. Never put `GEMINI_API_KEY` or an SSH key in `--dart-define`.

### Credentials needed

The complete local demo needs **no API key**. If optional AI context extraction is wanted, create one free-tier Gemini key in Google AI Studio and place only this line in the untracked root `.env` for development or `/etc/finguard/finguard.env` in production:

```dotenv
GEMINI_API_KEY=replace_with_your_key
```

Native QR scanning, SQLite, incident drafting, clipboard copy, native share, the UPI handoff, and the official reporting link need no API keys. FCM is intentionally not part of this MVP.

Email/password and guest access need no external identity service. To enable Google sign-in, create OAuth 2.0 clients in Google Cloud for the deployed Web origin and Android package/signing certificate. Put every accepted client ID in the server-side `GOOGLE_OAUTH_CLIENT_IDS`; pass the Web client ID as `GOOGLE_WEB_CLIENT_ID` and the Web/server client ID used by Android as `GOOGLE_ANDROID_SERVER_CLIENT_ID` at Flutter build time. OAuth client IDs are public identifiers, while `AUTH_SECRET_KEY` remains server-only. Google sign-in stays hidden when either side is not configured, so a partial configuration cannot produce a broken button.

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
| `POST` | `/api/v1/context/analyze` | Optional consent-gated context extraction with fallback |
| `POST` | `/api/v1/response/prepare` | Prepare prevention/recovery evidence and actions |
| `GET` | `/api/v1/history` | Assessment history for an anonymous device ID |
| `GET` | `/api/v1/demo/scenarios` | Stable labelled demo inputs and expected results |

All request models reject unknown fields. Validation errors are actionable and do not echo uploaded content. Screenshots are size/type/signature checked, are not logged, and are not stored.

The service stores scored payment requests under an anonymous device identifier, separate from the optional account identity, so it can protect response preparation from client-side tampering and provide assessment history without attaching payment facts to a login. On startup it deletes `ASSESSED` records older than `ASSESSMENT_RETENTION_DAYS` and removes expired or old revoked refresh sessions; seeded `COMPLETED` demo history is preserved. Clearing Flutter history removes the on-device copy only. Account deletion removes the account and its server sessions, while anonymous assessment retention remains governed by the retention policy.

## Deterministic demos

| Scenario | Evidence | Expected result |
|---|---|---:|
| Coffee-shop QR, known payee, INR 180 | Existing seeded device pattern | `SAFE 0/100` |
| Marketplace seller, first-time payee, INR 4,500 | First-time recipient + unusual amount | `CAUTION 33/100` |
| Fake KYC request, seeded VPA, INR 25,000 | Seed match + relationships + amount + KYC/urgency | `HIGH RISK 99/100` |

The Flutter client includes matching bundled fixtures so the three judge cases remain usable if the network or Gemini is unavailable. Seeded data is always labelled as demo data and is never presented as live bank, NPCI, or national fraud intelligence.

## Verification

Backend:

```powershell
cd backend
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m pytest
```

Flutter:

```powershell
cd frontend
flutter analyze
flutter test
flutter build web --release
flutter build apk --release
```

CI runs backend lint/tests, Flutter analysis/tests, and release Web and Android builds on every push and pull request.

## OCI Always Free deployment

The production target is an Ubuntu ARM64 VM using one Uvicorn worker behind Nginx:

```text
/opt/finguard/backend/       API source and virtual environment
/opt/finguard/web/           Flutter Web build
/var/lib/finguard/           SQLite state
/etc/finguard/finguard.env   root-managed server configuration/secrets
```

Follow [deploy/README.md](deploy/README.md) for one-time host setup, DNS, free Let's Encrypt issuance, renewal verification, service checks, and rollback-safe release activation.

GitHub deployment requires these repository or `production` environment secrets:

- `OCI_HOST`: VM public hostname or IPv4 address.
- `OCI_USER`: SSH account, normally `ubuntu`.
- `OCI_SSH_KEY`: complete unencrypted private deployment key.
- `OCI_KNOWN_HOSTS`: verified OpenSSH known-hosts line(s) for the VM.
- `DEPLOY_PATH`: absolute writable staging path, such as `/home/ubuntu/finguard-deploy`.
- `OCI_PORT`: optional; defaults to `22`.

It also accepts the public repository/environment variable `GOOGLE_WEB_CLIENT_ID` for the Web build. Production server configuration must provide a unique `AUTH_SECRET_KEY` and the matching `GOOGLE_OAUTH_CLIENT_IDS`.

Keep `GEMINI_API_KEY` on the server, not in GitHub Actions. Certbot asks for a certificate email address during setup but no API key and no paid certificate.

## Zero-cost design

- SQLite has no hosted database cost.
- The core parser, score, report builder, and demo fixtures work offline from paid services.
- Gemini is optional and can use its free Developer API tier; quota failure degrades to local deterministic analysis.
- Native share replaces paid SMS/email providers.
- OCI Always Free is the intended host; Nginx, systemd, and Let's Encrypt are free.
- No automatic paid upgrade or billing-dependent integration exists.

## Operational boundaries

- A SAFE result means no configured warning signal was found; it is not a guarantee that a recipient is legitimate.
- FinGuard checks a request before handoff. It cannot observe what the user later approves in a UPI app.
- It has no bank-internal, NPCI-internal, VPA-age, transaction-reversal, or government-report-submission access.
- Recipient reputation and relationship counts are clearly labelled seeded hackathon fixtures.
- Incident drafts and share messages remain on screen until the user explicitly copies, opens, or sends them.
- Account sessions are production-hardened for this single-node deployment, but email verification and password recovery require choosing and configuring a transactional email provider before a public launch.
- SQLite and one API worker are intentional for the included zero-cost OCI deployment. Horizontal scale requires a versioned migration to managed PostgreSQL/shared persistence and should be completed before traffic exceeds a single-node workload.
- Store-distributed Android releases require a private Play signing key, package registration, and a Google OAuth Android client bound to the final signing certificate.
