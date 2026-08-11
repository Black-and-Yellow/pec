# FinGuard architecture

## Product boundary

FinGuard is a pre-payment QR and UPI-link safety layer.

> FinGuard does not intercept transactions inside third-party UPI applications. It evaluates the payment before handoff.

The validated sequence is:

```text
physical QR / QR image / pasted UPI URI
                  |
                  v
       strict upi://pay parsing
                  |
                  v
 optional consent-gated context extraction
                  |
                  v
 deterministic, explainable risk policy
                  |
                  v
       SAFE / CAUTION / HIGH RISK
                  |
                  v
        explicit user decision
                  |
                  v
 normal UPI app or protective/recovery action
```

FinGuard never executes a payment, sends a report, or alerts a contact by itself.

## Components

### Flutter client

The single `frontend/` codebase targets Android and Web. It owns presentation and explicit user intent:

- camera QR scan and QR-image upload;
- pasted UPI input;
- responsive risk/evidence views;
- confirmation dialogs before caution/high-risk handoff or external actions;
- native clipboard, share sheet, browser, and UPI-scheme launch;
- optional email/password or Google identity, with an explicit account-free guest path;
- short-lived access tokens held in memory and rotating refresh tokens held in platform secure storage;
- an anonymous device identifier and compact on-device check history;
- bundled deterministic demos for outage-safe judging.

The client validates that a scanned value is `upi://pay` before calling the API and validates it again before external handoff. It never receives the Gemini key.

### FastAPI modular monolith

The `backend/app/` package separates HTTP routes, schemas, small domain services, repositories, integrations, and database code without adding network boundaries:

```text
api/routes -> Pydantic schemas -> domain services -> repositories -> SQLite
                                  |
                                  `-> optional Gemini HTTP adapter
```

- `upi_parser.py` accepts only the supported UPI payment form, limits query fields/length, rejects duplicates and malformed percent encoding, validates VPA/amount/currency, and produces typed payment details.
- `risk_engine.py` is synchronous, deterministic, independently testable, and has no network or LLM dependency.
- `context_analyzer.py` validates upload content, uses local text rules as a fallback, and calls Gemini only after explicit consent and configuration.
- `response_builder.py` prepares prevention/recovery facts and marks every external action that requires confirmation.
- repositories isolate SQLAlchemy queries and persistence from route/service logic.
- `auth_service.py` owns Argon2 password verification, Google ID-token verification, signed access tokens, opaque refresh-token rotation, and account deletion.

### SQLite

The minimum useful entities are retained:

- `Transaction`: parsed payment facts, device ID, source, and status;
- `RiskAssessment`: score, level, recommendation, and time;
- `RiskSignalRecord`: ordered explainable score contributions;
- `FraudIndicator`: transparently seeded demo VPA and identifier relationships.
- `User`: the optional FinGuard identity, intentionally separate from payment records;
- `RefreshSession`: only a SHA-256 hash of each opaque refresh token, with expiry and revocation time.

Only rows explicitly marked `COMPLETED` in seeded history influence known-payee and typical-amount calculations. Merely scoring a request does not pretend it was paid.

Scored requests are retained temporarily for response-integrity checks and optional assessment history. Startup cleanup removes `ASSESSED` rows older than the configured retention period (30 days by default) while preserving seeded `COMPLETED` history. The Flutter history screen keeps a separate on-device copy.

Account identity is not required for payment safety and is not used as a foreign key on assessed payment facts. Access tokens last 15 minutes by default and are held only in client memory. Refresh tokens rotate on every use, are stored with platform secure storage on the client, are hashed at rest on the server, and are removed after expiry/revocation. Deleting an account cascades to all of its server sessions.

## Risk policy

The final score is the sum of applicable configured signal weights, clamped to 0-100. No LLM assigns or overrides it.

| Signal | Weight |
|---|---:|
| Seeded fraud-recipient match | 30 |
| First-time payee on the device | 18 |
| Unusual amount for a new payee | 15 |
| Suspicious payment-note language | 10 |
| Seeded identifier relationships | 8 |
| Context impersonation | 8 |
| Context urgency | 8 |
| Context KYC/account threat | 10 |
| Context reward/refund claim | 6 |
| Context suspicious-support claim | 8 |

Context flags contribute only when their validated extraction confidence is at least `0.55`. `payment_requested` is contextual evidence but has no independent weight, avoiding double-counting the payment request itself.

Central thresholds are:

- `0-29`: SAFE;
- `30-69`: CAUTION;
- `70-100`: HIGH RISK.

For a first-time payee, the amount signal activates at the greater of INR 2,000 or three times the device's median completed payment. With no completed history it activates at INR 4,000. These are explainable hackathon policy values, not a trained fraud model.

## Optional AI boundary

```text
user text/image + explicit consent
              |
              v
Gemini structured JSON extraction
              |
              v
strict ContextSignals validation
              |
              v
deterministic risk engine
```

Gemini may flag impersonation, urgency, KYC threat, reward/refund language, a payment request, and suspicious support claims. It may not determine recipient reputation, assign a score/verdict, perform a report, or invent history. Provider errors, timeouts, quota exhaustion, missing keys, or malformed structured output return a normal fallback response rather than failing payment parsing/scoring.

Screenshots are decoded only in memory, limited by configured size, checked against PNG/JPEG/WebP magic bytes, excluded from logging, and not persisted.

## Human-control boundary

| Action | Confirmation behavior |
|---|---|
| Stop here / review evidence | No external side effect |
| SAFE handoff | User presses the UPI handoff button |
| CAUTION/HIGH handoff | Additional explicit warning confirmation |
| Prepare incident draft | Confirmation; local/server draft only |
| Copy draft | User presses copy |
| Share trusted-contact message | Confirmation opens native share sheet; user chooses recipient and sends |
| Open cybercrime portal | Confirmation opens the official website; nothing is submitted |
| Use 1930 recovery guidance | The UI displays the official helpline; the user places any call outside FinGuard |

API responses state `external_actions_performed: false` and describe FinGuard's inability to freeze/reverse/intercept payments.

## Security and privacy

- Environment variables and root-managed production files hold secrets.
- Production CORS requires explicit origins and rejects wildcard configuration.
- Unknown JSON fields are rejected.
- UPI input, amounts, identifiers, upload size, MIME declarations, and actual file signatures are validated.
- Request logs contain method, path, status, duration, and a random request ID, not payment content or uploaded screenshots.
- The production API binds only to loopback behind Nginx and HTTPS.
- Argon2 password hashing, strict JWT issuer/audience/type checks, refresh replay rejection, and narrower authentication rate limits protect the account surface.
- The systemd service runs as a dedicated non-root account with a read-only system, a single writable state directory, capability removal, and memory/task limits.

## Deployment

```text
Internet :443
     |
   Nginx
   /   \
  /     `-- /api/* -> 127.0.0.1:8000 -> one Uvicorn worker -> SQLite
 `-- / -> /opt/finguard/web (Flutter static build)
```

The one-worker native runtime is intentional for an OCI Always Free ARM64 VM with roughly 1 OCPU/2 GB RAM. Nginx provides TLS termination and Flutter client-side routing. systemd provides bounded restart behavior and journald logging. Runtime state and secrets stay outside the source/deployment tree.

GitHub Actions tests backend and Flutter code before the main-branch deploy workflow packages only runtime backend files, the Web build, and deployment assets. SSH stages the archive; the server validates paths/content, installs dependencies before replacing source, restarts the service, checks `/api/v1/health`, and reloads Nginx.

## Scaling boundary

The included deployment is a production-hardened single-node baseline. It deliberately avoids Redis, queues, microservices, Kubernetes, paid notification providers, banking integrations, and automatic reporting. A multi-node rollout must first replace SQLite with shared managed persistence and introduce versioned migrations. Email verification/password recovery also requires a selected transactional email provider. Those are infrastructure integrations, not hidden local code switches.
