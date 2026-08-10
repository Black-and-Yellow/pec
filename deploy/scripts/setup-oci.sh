#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE_USER="finguard"
readonly SERVICE_GROUP="finguard"
readonly APP_ROOT="/opt/finguard"
readonly STATE_ROOT="/var/lib/finguard"
readonly CONFIG_ROOT="/etc/finguard"

fail() {
  printf 'setup-oci: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run this script with sudo"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

[[ -f "${DEPLOY_DIR}/systemd/finguard-api.service" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/nginx/finguard-http.conf" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/finguard.env.example" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/scripts/deploy-release.sh" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/certbot/reload-nginx.sh" ]] || fail "deployment assets are incomplete"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends \
  ca-certificates \
  certbot \
  curl \
  nginx \
  python3 \
  python3-pip \
  python3-venv \
  rsync

if ! getent group "${SERVICE_GROUP}" >/dev/null; then
  groupadd --system "${SERVICE_GROUP}"
fi

if ! id --user "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "${SERVICE_GROUP}" \
    --home-dir /nonexistent \
    --no-create-home \
    --shell /usr/sbin/nologin \
    "${SERVICE_USER}"
fi
[[ "$(id --user "${SERVICE_USER}")" != 0 ]] || fail "service account must not be root"

install -d -o root -g root -m 0755 "${APP_ROOT}"
install -d -o root -g "${SERVICE_GROUP}" -m 0750 "${APP_ROOT}/backend"
install -d -o root -g www-data -m 0755 "${APP_ROOT}/web"
install -d -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" -m 0750 "${STATE_ROOT}"
install -d -o root -g "${SERVICE_GROUP}" -m 0750 "${CONFIG_ROOT}"
install -d -o root -g root -m 0755 /var/www/letsencrypt
install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy

[[ ! -L "${CONFIG_ROOT}/finguard.env" ]] || \
  fail "${CONFIG_ROOT}/finguard.env must not be a symlink"
if [[ ! -e "${CONFIG_ROOT}/finguard.env" ]]; then
  install -o root -g "${SERVICE_GROUP}" -m 0640 \
    "${DEPLOY_DIR}/finguard.env.example" \
    "${CONFIG_ROOT}/finguard.env"
  printf 'Created %s/finguard.env; review it before the first deployment.\n' "${CONFIG_ROOT}"
elif [[ -f "${CONFIG_ROOT}/finguard.env" && ! -L "${CONFIG_ROOT}/finguard.env" ]]; then
  chown root:"${SERVICE_GROUP}" "${CONFIG_ROOT}/finguard.env"
  chmod 0640 "${CONFIG_ROOT}/finguard.env"
  printf 'Preserved existing %s/finguard.env.\n' "${CONFIG_ROOT}"
else
  fail "${CONFIG_ROOT}/finguard.env must be a regular, non-symlink file"
fi

install -o root -g root -m 0644 \
  "${DEPLOY_DIR}/systemd/finguard-api.service" \
  /etc/systemd/system/finguard-api.service
install -o root -g root -m 0755 \
  "${DEPLOY_DIR}/certbot/reload-nginx.sh" \
  /etc/letsencrypt/renewal-hooks/deploy/finguard-reload-nginx
install -o root -g root -m 0755 \
  "${DEPLOY_DIR}/scripts/deploy-release.sh" \
  /usr/local/sbin/finguard-deploy-release

# Do not replace an HTTPS configuration when this idempotent setup is rerun.
[[ ! -L /etc/nginx/sites-available/finguard ]] || \
  fail "Nginx site path must not be a symlink"
if [[ ! -e /etc/nginx/sites-available/finguard ]]; then
  install -o root -g root -m 0644 \
    "${DEPLOY_DIR}/nginx/finguard-http.conf" \
    /etc/nginx/sites-available/finguard
fi
[[ -f /etc/nginx/sites-available/finguard && ! -L /etc/nginx/sites-available/finguard ]] || \
  fail "Nginx site path must be a regular, non-symlink file"

if [[ -L /etc/nginx/sites-enabled/finguard ]]; then
  [[ "$(readlink /etc/nginx/sites-enabled/finguard)" == /etc/nginx/sites-available/finguard ]] || \
    fail "existing FinGuard Nginx symlink points somewhere unexpected"
elif [[ -e /etc/nginx/sites-enabled/finguard ]]; then
  fail "existing FinGuard Nginx site is not a symlink"
else
  ln -s /etc/nginx/sites-available/finguard /etc/nginx/sites-enabled/finguard
fi

if [[ -L /etc/nginx/sites-enabled/default ]]; then
  unlink /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl daemon-reload
systemctl enable --now nginx
systemctl enable finguard-api.service

printf '\nOCI host setup is ready. Next:\n'
printf '  Architecture detected: %s (arm64 is the intended OCI target).\n' "$(dpkg --print-architecture)"
printf '  1. Edit /etc/finguard/finguard.env.\n'
printf '  2. Deploy a release through GitHub Actions.\n'
printf '  3. Point DNS at this VM and run enable-https.sh.\n'
