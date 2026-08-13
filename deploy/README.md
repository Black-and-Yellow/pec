# FinGuard on OCI Always Free

This deployment targets an Ubuntu 24.04 ARM64 VM such as OCI
`VM.Standard.A1.Flex` with about one OCPU and 2 GB RAM. It uses one-time
architecture-native apt packages, a release-signed ARM64 Python wheelhouse,
Nginx, one Uvicorn worker, systemd, and SQLite. It does not install Docker or
require an x86 compatibility layer.

## Production layout

```text
/opt/finguard/backend/       FastAPI source and release-local .venv
/opt/finguard/web/           Flutter web build
/var/lib/finguard/           SQLite database
/etc/finguard/finguard.env   server-only configuration and optional Gemini key
/etc/finguard/release_allowed_signers  root-controlled release public key
/home/finguard-deploy/finguard-deploy/  fixed serialized stream staging directory
```

The `finguard` runtime account and separate `finguard-build` account both have
no login shell and do not share a group. The build account can write only to a
temporary candidate workspace while it creates and validates a release; it
cannot read the live backend, server configuration, or runtime state. The
hardened service may write only under `/var/lib/finguard`, and Uvicorn listens
only on `127.0.0.1:8000`. Nginx is the sole public application listener.

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

Host setup uses Ubuntu's configured apt repositories to install OS packages.
That is a deliberate one-time/update-time network operation, separate from a
release activation. The release runner never downloads Python dependencies.

The setup is idempotent: it preserves the server environment and refreshes any
activated HTTPS site from the current trusted template. The refresh strictly
recovers one matching domain and its canonical Let's Encrypt certificate paths,
then fully renders a root-owned mode-`0644` candidate beside the active file,
backs up the active bytes, atomically renames the candidate into place, validates,
and reloads Nginx. A failed replacement leaves the active file unchanged. If
candidate validation or reload fails, it restores, revalidates, and reloads the
prior site; if rollback itself fails, it preserves the backup path for operator
recovery. It installs the release runner at
`/usr/local/sbin/finguard-deploy-release` as a root-owned file. Rerun setup from
a trusted checkout whenever the systemd unit or release runner changes.
It also creates a root-owned, mode `0600`, empty
`/etc/finguard/release_allowed_signers` placeholder and preserves a configured
regular file on later runs. Deployment fails closed until that trust file
contains the dedicated release-signing public key. Setup also creates the
password-locked `finguard-deploy` SSH transport account, removes all of its
supplementary groups on every run, creates its fixed staging directory, and
installs a root-owned mode-`0440` sudoers rule for only the exact two-argument
forward release command. The account shell is the root-owned deployment
transport dispatcher, not an interactive shell. Its home, `.ssh` directory,
and `authorized_keys` boundary are root-controlled while only the fixed staging
directory is writable by the transport account. The sudo rule is validated
with `visudo` during setup.

Create the release signer on a trusted administrator machine. This identity
must be dedicated to release signing and must not be the OCI SSH transport key:

```bash
umask 077
ssh-keygen -q -t ed25519 -N '' -C finguard-release -f finguard-release-signing
printf 'finguard-ci %s\n' "$(cut -d ' ' -f 1-2 finguard-release-signing.pub)" > release_allowed_signers
```

Transfer only `release_allowed_signers` to a trusted administrator location on
the OCI host, inspect it there, then install it:

```bash
sudo install -o root -g root -m 0600 release_allowed_signers /etc/finguard/release_allowed_signers
```

Store the complete unencrypted private file `finguard-release-signing` only in
the GitHub `production` environment secret `RELEASE_SIGNING_KEY`. Back it up in
an operator-controlled secret manager or offline encrypted vault. The host gets
only the single-line public trust record. Confirm the installed file is exactly
one `finguard-ci ssh-ed25519 ...` line; comments, blank lines, additional keys,
other principals, symlinks, or looser ownership/modes are intentionally rejected.

Create a separate Ed25519 SSH transport key on the trusted administrator
machine; do not create or store either half or the generated authorization
record in this repository. Convert its public half into the one exact restricted
record shown below. OpenSSH `restrict` disables port, agent, and X11 forwarding,
PTY allocation, and user rc processing; the forced command permits only one
bounded streamed release-and-activation operation.

```bash
ssh-keygen -q -t ed25519 -N '' -C finguard-transport -f finguard-transport
transport_public="$(cut -d ' ' -f 1-2 finguard-transport.pub)"
printf 'restrict,command="/usr/local/libexec/finguard-deploy-transport" %s finguard-transport\n' \
  "${transport_public}" > finguard-transport.authorized_keys
scp finguard-transport.authorized_keys \
  ubuntu@finguard.example.dev:/tmp/finguard-transport.authorized_keys
ssh ubuntu@finguard.example.dev
sudo install -o root -g finguard-deploy -m 0640 \
  /tmp/finguard-transport.authorized_keys \
  /home/finguard-deploy/.ssh/authorized_keys
rm -f /tmp/finguard-transport.authorized_keys
sudo bash ./deploy/scripts/setup-oci.sh
```

Store only the complete private `finguard-transport` file in the GitHub
`production` environment secret `OCI_SSH_KEY`. The final setup rerun validates
that `authorized_keys` is one root-owned, non-symlink, mode-`0640` Ed25519 record
with exactly the forced-command prefix; malformed, multiple, or unrestricted
records are disabled. Confirm the streamed activation workflow works before
removing any obsolete administrator access. An empty file intentionally leaves
the transport identity disabled during bootstrap. Its dedicated group has read
access so `sshd` can load it as the target account, but the account has no write
access to the file or its parent directory.

The safe bootstrap order is mandatory:

1. run setup and review `/etc/finguard/finguard.env`;
2. install the dedicated release-signing and SSH transport public keys as
   described above;
3. point public DNS at the VM;
4. run `enable-https.sh` to issue the certificate and install the HTTPS site;
5. only then perform the first application deployment and use FinGuard.

Before step 3, the HTTP bootstrap site serves only ACME challenge files and an
inert `503` response. It does not proxy the API or serve the Flutter UI, so no
FinGuard input surface is public over plaintext.

The real environment file must be mode `0640`, owned by `root:finguard`. Set the
following values:

- `APP_ENV=production`
- `LOG_LEVEL`: application log level, normally `INFO`.
- `DATABASE_URL=sqlite:////var/lib/finguard/finguard.db`
- `ALLOWED_ORIGINS`: comma-separated exact HTTPS origins; never `*` in production.
- `ENABLE_AI_CONTEXT`: defaults to `false`. Set it to `true` only deliberately
  and only when `GEMINI_API_KEY` and provider-side budget monitoring are ready.
- `GEMINI_API_KEY`: server-side Gemini key, required when AI is enabled. Leave
  it blank for deterministic-only operation.
- `GEMINI_MODEL`, `GEMINI_TIMEOUT_SECONDS`, and `MAX_SCREENSHOT_BYTES`: bounded
  optional-AI settings shown in `deploy/finguard.env.example`.
- `ASSESSMENT_RETENTION_DAYS`: bounded retention for scored request records;
  defaults to 30 days and does not remove seeded completed demo history.
- `MAX_ASSESSED_RECORDS_PER_DEVICE` and `MAX_ASSESSED_RECORDS_TOTAL`: hard
  oldest-first caps for assessed records; defaults are 50 per anonymous device
  and 5,000 for the service.
- `AUTH_SECRET_KEY`: unique random server secret of at least 32 characters. The
  documented `replace-with-at-least-32-random-characters` value is only a
  placeholder; both deployment preflight and production application startup
  fail until it is replaced. Never reuse a development value in production.
- `ACCESS_TOKEN_MINUTES` and `REFRESH_TOKEN_DAYS`: bounded session lifetimes;
  defaults are 15 minutes and 30 days.
- `MAX_REGISTERED_USERS`: single-process account-row ceiling; defaults to 5,000
  and must remain between 1 and 100,000.
- `GOOGLE_OAUTH_CLIENT_IDS`: comma-separated Web/Android OAuth client IDs whose
  Google ID tokens the API accepts. Leave blank to disable Google sign-in.

Do not put `GEMINI_API_KEY` in Flutter, GitHub Actions, or the repository.
FinGuard's scan, parse, and deterministic risk flow works without it.

Nginx applies the normal API limit and a stricter `2` requests/minute per-IP
limit (burst `1`) to `POST /api/v1/context/analyze`; preflight requests do not
consume that dedicated limit. This is a single-node cost/abuse bound, not an
identity control or a distributed quota guarantee. Before enabling public AI
traffic, configure and monitor a hard provider budget or an authenticated API
gateway quota. Keep AI disabled if neither control is available.

For login, registration, Google sign-in, and refresh, Nginx applies both a
`10` requests/minute per-IP limit (burst `5`) and a single-node global `30`
requests/minute budget (burst `10`). The global key is nonempty only for those
four exact auth routes, so it bounds aggregate password-hash and auth work even
when requests are distributed across source addresses. This deliberately trades
some availability during an auth surge for bounded CPU on the small VM: valid
users can receive `429` and must retry. It is neither a user identity nor a
distributed quota, and it would not coordinate across multiple Nginx nodes.

The backend also admits no more than `MAX_REGISTERED_USERS` accounts within the
documented single process. New password and first-time Google accounts share the
same process-local admission lock and return generic temporary unavailability at
capacity. Each auth/session operation removes only a bounded batch of expired or
old-revoked sessions, and each account retains at most five active refresh
sessions. These limits protect the one-worker SQLite target; they are not a
replacement for shared transactional admission and upstream abuse protection if
the service ever scales to multiple workers or nodes.

## GitHub Actions deployment

The deployment workflow runs after successful `CI` checks on a push to `main`.
A manual run is allowed only from `main` and repeats backend lint/tests and
Flutter analysis/tests before building. Immediately before opening the only
deployment stream, the workflow reads `refs/heads/main` from the authenticated
repository remote and requires it to equal the exact tested commit. A missing,
malformed, unreachable, or changed ref fails closed, so an older CI run that
finishes after a newer main revision cannot deploy stale code. There is no
remote release state before this check: the next operation creates an
uncompressed two-entry tar stream and pipes it through one SSH request.
After the host builds and validates the signed candidate, the forward runner
makes a second cache-busted, explicitly non-cacheable read from GitHub's fixed public API endpoint for
`Black-and-Yellow/pec` `refs/heads/main`. It requires strict JSON containing the
same lowercase 40-character commit signed into the release before it marks
activation started, stops the service, or swaps directories. HTTPS/TLS,
nonce, connection, total-time, response-size, HTTP, JSON, and mismatch failures all
fail closed before downtime. This unauthenticated read deliberately makes
forward activation depend on brief GitHub API availability; it sends no token
and stores the response only in the root-only temporary release directory.
CI cross-resolves every exact runtime
dependency, `pip`, and the PEP 517 build backend as binary wheels for Python 3.12
on Ubuntu ARM64. It then proves that the set resolves again with indexes disabled,
adds a checksum manifest, and signs one archive containing source, Web assets,
deployment assets, requirements, and the complete wheelhouse. The root runner
copies the archive and detached signature into a root-only temporary directory
and verifies the exact archive bytes before listing, extraction, or
artifact-derived execution. It then:

1. validates the signed archive, deployment assets, wheel filenames, and every
   wheel checksum;
2. uses the separate unprivileged build account to create, install, compile,
   and import-check a fresh native Python environment before downtime, using a
   root-owned read-only wheelhouse with pip indexes disabled;
3. swaps the backend and web directories;
4. starts the restricted service and checks API plus SQLite health;
5. reloads Nginx, or restores the previous release on failure.

Configure these repository or `production` environment secrets:

- `OCI_HOST` (required): VM DNS name or IPv4 address.
- `OCI_SSH_KEY` (required): complete unencrypted private deploy key.
- `OCI_KNOWN_HOSTS` (required): verified OpenSSH known-hosts line(s) for the VM.
- `RELEASE_SIGNING_KEY` (required): complete unencrypted private Ed25519 release
  key whose public half is installed on the host for principal `finguard-ci`.
- `OCI_PORT` (optional): SSH port; the default is `22`.

The workflow deliberately fixes the SSH login to `finguard-deploy`; it is not a
secret or operator-configurable input. It creates an uncompressed tar stream
containing only `finguard-release.tgz` and `finguard-release.tgz.sig`, then pipes
that stream once to SSH with the exact command
`finguard-deploy-activate-stream`. It does not upload or activate in separate
remote sessions.

Set the public repository/environment variable `GOOGLE_WEB_CLIENT_ID` when the
Web OAuth client is ready. It is embedded in the Flutter build and must also be
listed in the server's `GOOGLE_OAUTH_CLIENT_IDS`. No Google client secret is
used by the ID-token flow.

Use a dedicated Ed25519 deploy key. Both private keys must be unencrypted because
there is no interactive passphrase prompt, and the workflow verifies that the
release-signing key and SSH transport key are distinct Ed25519 identities. It
pins the server key from `OCI_KNOWN_HOSTS`; it never trusts a key learned during
the deployment itself. The ephemeral private-key files are removed even when a
later workflow step fails.
From a trusted administrator machine, collect the public host key and compare
its fingerprint with the key shown through the OCI console before saving the
known-hosts line as the secret:

```bash
ssh-keyscan -t ed25519 -p 22 finguard.example.dev > finguard_known_hosts
ssh-keygen -lf finguard_known_hosts
```

The dedicated SSH account has no interactive command or forwarding access. Its
single root-controlled `authorized_keys` record must begin exactly with:

```text
restrict,command="/usr/local/libexec/finguard-deploy-transport" ssh-ed25519
```

The root-owned dispatcher accepts only the exact SSH command
`finguard-deploy-activate-stream`. It serializes invocations on the fixed staging
directory before removing any failed prior fixed-path leftovers, bounds the
incoming container on disk, and requires exactly two expected regular non-link
entries. It validates the archive and signature sizes in an isolated
per-invocation directory and moves them to the fixed paths only immediately
before this setup-managed non-interactive sudo command:

```text
finguard-deploy ALL=(root) NOPASSWD: /usr/local/sbin/finguard-deploy-release /home/finguard-deploy/finguard-deploy/finguard-release.tgz /home/finguard-deploy/finguard-deploy/finguard-release.tgz.sig
```

Setup removes supplementary groups, so the transport account cannot inherit
OCI's broad Ubuntu sudo authority. The runner also validates the sudo identity,
installed command path, and both fixed arguments before accepting a forward
release. The dispatcher cleans incoming and fixed files on success, failure, or
signal and preserves the release runner's exit status. A malformed or oversized
stream never reaches sudo; the root runner remains responsible for authenticating
the exact archive signature before listing, extracting, or executing its
contents. Legacy SCP, bare activation, arbitrary commands, empty commands,
alternate paths, tunnels/forwarding, PTYs, and the rollback argument are
unavailable through this identity. Trusted local-root rollback is unchanged.

The workflow does not need OCI API credentials, a database password, a DNS API
token, a Certbot key, or a Gemini key.

Release activation performs no package-index or external artifact/dependency
fetch after signature verification. Its one deliberate external call is the
bounded, unauthenticated GitHub API read that confirms the signed forward
release is still current `main` immediately before downtime. `venv` bootstraps from the host Python's bundled
`ensurepip`; both the pip upgrade and the source build/install use only the
signed wheelhouse with `PIP_NO_INDEX=1`, `--no-index`, and binary-only dependency
selection. Apart from the GitHub freshness request, its only `curl` is the
loopback post-activation health check.
The signing boundary authenticates the exact wheel bytes selected by CI, so the
CI runner, configured Python package index/TLS path, release-signing key, and
reviewed exact version constraints remain trusted inputs. GitHub's x86 runner
can resolve and inspect ARM64 wheel metadata but cannot execute those native
wheels; the unprivileged compile/import check on the actual ARM64 host is the
final architecture-native gate before downtime.

The signature uses OpenSSH namespace `finguard-release` and allowed-signers
principal `finguard-ci`. A compromised writable SSH staging account can alter
or replace uploaded files, but cannot make altered bytes pass verification
without the separate release key. Keep production-environment approval and
private-key access restricted; any previously signed release remains authentic,
so intentional rollback still requires the same operational authorization as a
forward release.

### Release freshness and deliberate rollback

Every signed archive contains a strict `finguard-release-metadata-v1` record
with the positive canonical-decimal GitHub Actions `GITHUB_RUN_NUMBER` and the
exact 40-character lowercase commit ID built by the workflow. Because this
record is inside the signed archive, neither the SSH transport account nor an
archive replay can change its sequence or commit without invalidating the
signature.

The host keeps the highest sequence it has ever accepted in the root-owned,
mode `0600` `/etc/finguard/release_high_water` file. A normal two-argument
`finguard-deploy-release` invocation is always forward-only: it rejects a
sequence equal to or below that high-water value before artifact-derived code
runs. The GitHub deployment workflow uses only this two-argument form, so a
workflow rerun of the same signed release is rejected and the workflow cannot
request rollback.

Rollback is an exceptional, interactive operator action. After independently
verifying the intended older signed archive and its detached signature, a root
administrator may invoke the installed runner with the exact third argument:

```bash
sudo /usr/local/sbin/finguard-deploy-release \
  /trusted/staging/finguard-release.tgz \
  /trusted/staging/finguard-release.tgz.sig \
  --allow-rollback
```

The override accepts only a valid signed release whose sequence is below the
recorded high-water value; it does not accept an equal-sequence replay or a
newer release. A successful rollback deliberately leaves the high-water record
unchanged. Consequently, sequence 10 followed by an authorized rollback to 9
still rejects 10, and normal forward deployment resumes only at 11 or higher.
The setup-managed sudoers rule authorizes only the normal two-argument command,
and the runner independently rejects `--allow-rollback` when sudo identifies
the transport account. Keep rollback archives outside the transport-owned
staging directory and invoke the example only from a separate trusted local
administrator session.

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
installed deployment hook validates Nginx before reloading it. Until this HTTPS
step completes, the bootstrap site exposes neither the API nor the UI and must
not be used for application testing.

To apply a reviewed Nginx template update to an already-enabled host without
contacting Certbot or making any network request, run from the trusted checkout:

```bash
sudo bash ./deploy/scripts/https-config.sh --refresh-existing
```

The refresh rejects symlinked or malformed site/template paths, multiple or
mismatched domains, noncanonical certificate directives, missing certificate
files, and any candidate that would expose the application before TLS. The
existing configuration backup is retained until both `nginx -t` and reload
succeed. Rerunning `setup-oci.sh` performs the same HTTPS-template refresh after
its documented package-maintenance phase; use the direct command above for an
ordinary offline configuration refresh.

## Operations

```bash
sudo systemctl status finguard-api --no-pager
sudo journalctl -u finguard-api -n 100 --no-pager
curl --fail http://127.0.0.1:8000/api/v1/health
sudo nginx -t
```

The application logs to journald. Runtime state survives releases in
`/var/lib/finguard`; source releases and web assets remain root-owned.
