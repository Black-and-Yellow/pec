#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'enable-https: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run this script with sudo"
[[ $# -eq 2 ]] || fail "usage: $0 DOMAIN CERTIFICATE_EMAIL"

readonly DOMAIN="$1"
readonly CERTIFICATE_EMAIL="$2"

[[ "${DOMAIN}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || \
  fail "DOMAIN must be a valid DNS hostname"
[[ "${CERTIFICATE_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
  fail "CERTIFICATE_EMAIL is not valid"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly TEMPLATE="${DEPLOY_DIR}/nginx/finguard-https.conf.template"
readonly ACTIVE_CONFIG="/etc/nginx/sites-available/finguard"

[[ -f "${TEMPLATE}" ]] || fail "missing HTTPS Nginx template"
[[ -f "${DEPLOY_DIR}/scripts/https-config.sh" ]] || fail "missing HTTPS activation helper"
[[ -f "${ACTIVE_CONFIG}" && ! -L "${ACTIVE_CONFIG}" ]] || fail "run setup-oci.sh first"
[[ -x /etc/letsencrypt/renewal-hooks/deploy/finguard-reload-nginx ]] || \
  fail "Certbot renewal hook is missing; rerun setup-oci.sh"

install -d -o root -g root -m 0755 /var/www/letsencrypt

# The initial HTTP site serves only this ACME webroot, so Certbot does not need
# to edit Nginx or expose the application before TLS is active.
certbot certonly \
  --webroot \
  --webroot-path /var/www/letsencrypt \
  --domain "${DOMAIN}" \
  --email "${CERTIFICATE_EMAIL}" \
  --agree-tos \
  --non-interactive \
  --keep-until-expiring

[[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] || fail "certificate was not created"
[[ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]] || fail "certificate key was not created"
systemctl enable --now certbot.timer

bash "${DEPLOY_DIR}/scripts/https-config.sh" --domain "${DOMAIN}"

printf 'HTTPS enabled for %s. Verify renewal with: sudo certbot renew --dry-run\n' "${DOMAIN}"
