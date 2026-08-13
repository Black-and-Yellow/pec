# FinGuard Flutter client

One Flutter codebase serves Android and Web. It includes a responsive welcome/home experience, email/password and Google identity, account-free guest access, secure session restoration, account privacy controls, QR/link intake, explainable scoring, recovery, and deliberate UPI handoff.

FinGuard does not intercept, freeze, cancel, reverse or observe transactions inside third-party UPI apps.

## Run

Use the repository-verified Flutter 3.44.9 toolchain (Dart 3.12.2):

```powershell
cd frontend
flutter pub get
flutter run -d chrome --web-port 8080 --dart-define=API_BASE_URL=http://localhost:8000
```

For an Android emulator, the default API base is `http://10.0.2.2:8000`. For a physical phone, supply the development computer's reachable LAN address:

```powershell
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
```

Production Web defaults to the page origin. Nginx can therefore serve Flutter at `/` and proxy `/api/` without embedding a server address or secret:

```powershell
flutter build web --release
```

`API_BASE_URL` is a public endpoint, not an API key. Do not put Gemini or other server secrets in a Dart define.

## Google sign-in

Google OAuth is optional and appears only when both the API and the target build are configured. For Web, create a Google OAuth Web client with the exact local/production JavaScript origins, add its ID to backend `GOOGLE_OAUTH_CLIENT_IDS`, then run/build with:

```powershell
flutter run -d chrome --web-port 8080 `
  --dart-define=API_BASE_URL=http://localhost:8000/ `
  --dart-define=GOOGLE_WEB_CLIENT_ID=123-example.apps.googleusercontent.com
```

For Android, register package `org.pec.finguard` and the final signing certificate SHA-1/SHA-256 in Google Cloud. Add both accepted OAuth IDs to the backend and pass the Web/server client ID used for backend ID-token verification:

```powershell
flutter build apk --release `
  --dart-define=API_BASE_URL=https://finguard.example.dev/ `
  --dart-define=GOOGLE_ANDROID_SERVER_CLIENT_ID=123-example.apps.googleusercontent.com
```

Client IDs are public configuration. Never put a Google client secret, backend auth signing key, Gemini key, keystore, or password in Dart defines.

## Verify

```powershell
flutter analyze
flutter test
flutter build web --release
flutter build apk --release `
  --dart-define=API_BASE_URL=https://finguard.example.dev/
```

The Android bootstrap downloads the pinned Gradle 8.14 distribution on its first build and verifies it against Gradle's published SHA-256 checksum. Release builds fail closed when production signing is absent. For a distributable release, set all four signing variables before building:

```powershell
$env:FINGUARD_KEYSTORE_PATH='C:\secure\finguard-release.jks'
$env:FINGUARD_KEYSTORE_PASSWORD='...'
$env:FINGUARD_KEY_ALIAS='finguard'
$env:FINGUARD_KEY_PASSWORD='...'
flutter build apk --release `
  --dart-define=API_BASE_URL=https://finguard.example.dev/
```

Release-producing Gradle graphs, including aggregate `assemble`, fail before execution unless the HTTPS API origin and all four signing values are present. For compile evidence only, CI and `scripts/verify.ps1` explicitly set `FINGUARD_ALLOW_DEMO_RELEASE=true`; that debug-signed artifact is non-distributable. Never commit the keystore or passwords. These signing values are not service API keys.

## API assumptions

- `POST /api/v1/payments/parse` with `{"upi_uri":"upi://pay?..."}` returns payment fields under `payment` plus a server-built `canonical_uri`. Only that canonical URI is retained for handoff.
- `POST /api/v1/risk/score` sends the backend `PaymentDetails` shape (`vpa`, `payee_name`, `amount`, `transaction_note`, `currency`, and `transaction_reference`) with an explicit anonymous `device_id`. Optional context is sent only together with the short-lived integrity token returned by context analysis.
- A live score is accepted only as the exact complete server envelope: assessment and transaction IDs, echoed payment, score, exact `SAFE`/`CAUTION`/`HIGH` level, signals, recommendation, confirmation flag, handoff policy, and timezone-aware assessment time. The echoed payment and control matrix must match the checked request before a handoff can be enabled.
- Each signal has `code`, `label`, integer `weight`, and `evidence`.
- `POST /api/v1/context/analyze` accepts selected text and an optional size/type-checked PNG, JPEG or WebP screenshot. `consent_to_external_ai` is false unless the user explicitly enables Gemini. A usable response carries schema-bounded signals plus the matching short-lived integrity token; unavailable or stale analysis is not forwarded as context. Local text rules and deterministic payment scoring remain available when Gemini is disabled or over quota.
- `POST /api/v1/response/prepare` accepts strict payment, assessment, context and `already_paid` objects. The client formats its structured incident report and falls back to a complete deterministic local draft if the service is unavailable.
- The three home-screen scenarios are bundled, clearly labelled fixtures so SAFE (0), CAUTION (33), and HIGH RISK (99) remain immediate and deterministic without a server or AI connection. They mirror the backend demo data.

The client accepts only validated `upi://pay` input with a valid `pa` recipient, INR currency and safe amount. Duplicate fields, malformed VPAs, arbitrary scanned URLs and non-canonical handoff data are rejected. Every UPI handoff, native share, report preparation, and official cybercrime route is kept behind an explicit user action or confirmation.

The refresh credential is stored with platform secure storage and rotated by the API; access credentials remain in memory. Guest mode stores only a local preference. A signed-in user can revoke the local session or permanently delete the FinGuard identity and all server sessions from Account & privacy.
