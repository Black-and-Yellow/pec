# FinGuard on OCI Always Free

This deployment targets an Ubuntu 24.04 ARM64 VM such as OCI
`VM.Standard.A1.Flex` with about one OCPU and 2 GB RAM. It uses architecture-
native apt/pip packages, Nginx, one Uvicorn worker, systemd, and SQLite. It does
not install Docker or require an x86 compatibility layer.

## Production layout

```text
/opt/finguard/backend/       FastAPI source and release-local .venv
/opt/finguard/web/           Flutter web build
/var/lib/finguard/           SQLite database
/etc/finguard/finguard.env   server-only configuration and optional Gemini key
```

The `finguard` system account has no login shell. The hardened service may write
only under `/var/lib/finguard`, and Uvicorn listens only on `127.0.0.1:8000`.
Nginx is the sole public application listener.

## One-time OCI host setup

Use an Ubuntu 24.04 ARM64 image. In the OCI network security list or NSG, permit
TCP 80 and 443 publicly and restrict TCP 22 to trusted administrator addresses
where practical. A quick architecture check should print `arm64`:

```bash
dpkg --print-architecture
```

Copy this `deploy` directory from a trusted checkout to the VM and run:

```bash
sudo bash ./deploy/scripts/setup-oci.sh
sudoedit /etc/finguard/finguard.env
```

The setup is idempotent: it preserves the server environment and any activated
HTTPS site. It installs the release runner at
`/usr/local/sbin/finguard-deploy-release` as a root-owned file. Rerun setup from
a trusted checkout whenever the systemd unit or release runner changes.

The real environment file must be mode `0640`, owned by `root:finguard`. Set the
following values:

- `APP_ENV=production`
- `LOG_LEVEL`: application log level, normally `INFO`.
- `DATABASE_URL=sqlite:////var/lib/finguard/finguard.db`
- `ALLOWED_ORIGINS`: comma-separated exact HTTPS origins; never `*` in production.
- `ENABLE_AI_CONTEXT`: keep `true` to use Gemini when a key is present, or set
  `false` to disable all AI context calls.
- `GEMINI_API_KEY`: optional server-side Gemini free-tier key. Leave blank for
  deterministic-only operation.
- `GEMINI_MODEL`, `GEMINI_TIMEOUT_SECONDS`, and `MAX_SCREENSHOT_BYTES`: bounded
  optional-AI settings shown in `deploy/finguard.env.example`.
- `ASSESSMENT_RETENTION_DAYS`: bounded retention for scored request records;
  defaults to 30 days and does not remove seeded completed demo history.
- `AUTH_SECRET_KEY`: unique random server secret of at least 32 characters. Never
  reuse the example development value in production.
- `ACCESS_TOKEN_MINUTES` and `REFRESH_TOKEN_DAYS`: bounded session lifetimes;
  defaults are 15 minutes and 30 days.
- `GOOGLE_OAUTH_CLIENT_IDS`: comma-separated Web/Android OAuth client IDs whose
  Google ID tokens the API accepts. Leave blank to disable Google sign-in.

Do not put `GEMINI_API_KEY` in Flutter, GitHub Actions, or the repository.
FinGuard's scan, parse, and deterministic risk flow works without it.

## GitHub Actions deployment

The deployment workflow runs after successful `CI` checks on a push to `main`.
A manual run is allowed only from `main` and repeats backend lint/tests and
Flutter analysis/tests before building. CI uploads one release archive, invokes
the root-owned runner, then the runner:

1. validates the archive and deployment assets;
2. creates a fresh native Python virtual environment before downtime;
3. swaps the backend and web directories;
4. starts the restricted service and checks API plus SQLite health;
5. reloads Nginx, or restores the previous release on failure.

Configure these repository or `production` environment secrets:

- `OCI_HOST` (required): VM DNS name or IPv4 address.
- `OCI_USER` (required): dedicated SSH login, commonly `ubuntu`.
- `OCI_SSH_KEY` (required): complete unencrypted private deploy key.
- `OCI_KNOWN_HOSTS` (required): verified OpenSSH known-hosts line(s) for the VM.
- `DEPLOY_PATH` (required): staging directory below that user's home, for example
  `/home/ubuntu/finguard-deploy`.
- `OCI_PORT` (optional): SSH port; the default is `22`.

Set the public repository/environment variable `GOOGLE_WEB_CLIENT_ID` when the
Web OAuth client is ready. It is embedded in the Flutter build and must also be
listed in the server's `GOOGLE_OAUTH_CLIENT_IDS`. No Google client secret is
used by the ID-token flow.

Use a dedicated Ed25519 deploy key. The workflow rejects encrypted private keys
because there is no interactive passphrase prompt. It pins the server key from
`OCI_KNOWN_HOSTS`; it never trusts a key learned during the deployment itself.
From a trusted administrator machine, collect the public host key and compare
its fingerprint with the key shown through the OCI console before saving the
known-hosts line as the secret:

```bash
ssh-keyscan -t ed25519 -p 22 finguard.example.dev > finguard_known_hosts
ssh-keygen -lf finguard_known_hosts
```

The SSH account needs non-interactive sudo only for the installed runner. OCI's
default Ubuntu account generally already has passwordless sudo. A narrower
sudoers rule can instead be created with `visudo`; substitute the actual user
and exact staging path:

```text
ubuntu ALL=(root) NOPASSWD: /usr/local/sbin/finguard-deploy-release /home/ubuntu/finguard-deploy/finguard-release.tgz
```

The workflow does not need OCI API credentials, a database password, a DNS API
token, a Certbot key, or a Gemini key.

## DNS and free HTTPS

Create an `A` record for the chosen domain pointing to the VM's reserved public
IP. Once public DNS resolves, issue a free Let's Encrypt certificate and switch
to HTTPS:

```bash
sudo bash ./deploy/scripts/enable-https.sh finguard.example.dev you@example.dev
sudo certbot renew --dry-run
systemctl status certbot.timer --no-pager
```

Replace both example values. Certbot's timer renews the certificate; the
installed deployment hook validates Nginx before reloading it. The initial site
supports temporary HTTP testing by public IP, but do not use that mode for a
real payment-safety demo or sensitive context input.

## Operations

```bash
sudo systemctl status finguard-api --no-pager
sudo journalctl -u finguard-api -n 100 --no-pager
curl --fail http://127.0.0.1:8000/api/v1/health
sudo nginx -t
```

The application logs to journald. Runtime state survives releases in
`/var/lib/finguard`; source releases and web assets remain root-owned.
