#!/usr/bin/env bash
set -Eeuo pipefail

readonly SERVICE_USER="finguard"
readonly SERVICE_GROUP="finguard"
readonly BUILD_USER="finguard-build"
readonly BUILD_GROUP="finguard-build"
readonly DEPLOY_USER="finguard-deploy"
readonly DEPLOY_GROUP="finguard-deploy"
readonly DEPLOY_HOME="/home/finguard-deploy"
readonly DEPLOY_STAGING_ROOT="${DEPLOY_HOME}/finguard-deploy"
readonly DEPLOY_RUNNER="/usr/local/sbin/finguard-deploy-release"
readonly DEPLOY_TRANSPORT="/usr/local/libexec/finguard-deploy-transport"
readonly DEPLOY_AUTHORIZED_KEYS="${DEPLOY_HOME}/.ssh/authorized_keys"
readonly DEPLOY_AUTHORIZED_KEY_REGEX='^restrict,command="/usr/local/libexec/finguard-deploy-transport" ssh-ed25519 [A-Za-z0-9+/]+={0,2} finguard-transport$'
readonly DEPLOY_SUDOERS_FILE="/etc/sudoers.d/finguard-deploy"
readonly DEPLOY_SUDOERS_RULE="finguard-deploy ALL=(root) NOPASSWD: /usr/local/sbin/finguard-deploy-release /home/finguard-deploy/finguard-deploy/finguard-release.tgz /home/finguard-deploy/finguard-deploy/finguard-release.tgz.sig"
readonly APP_ROOT="/opt/finguard"
readonly STATE_ROOT="/var/lib/finguard"
readonly CONFIG_ROOT="/etc/finguard"
readonly ALLOWED_SIGNERS_FILE="${CONFIG_ROOT}/release_allowed_signers"
readonly RELEASE_HIGH_WATER_FILE="${CONFIG_ROOT}/release_high_water"
readonly RELEASE_HIGH_WATER_LOCK="${CONFIG_ROOT}/release_high_water.lock"

fail() {
  printf 'setup-oci: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run this script with sudo"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

[[ -f "${DEPLOY_DIR}/systemd/finguard-api.service" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/nginx/finguard-http.conf" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/nginx/finguard-https.conf.template" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/finguard.env.example" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/scripts/deploy-release.sh" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/scripts/deploy-transport.sh" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/scripts/https-config.sh" ]] || fail "deployment assets are incomplete"
[[ -f "${DEPLOY_DIR}/certbot/reload-nginx.sh" ]] || fail "deployment assets are incomplete"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install --yes --no-install-recommends \
  ca-certificates \
  certbot \
  curl \
  iptables-persistent \
  nginx \
  openssh-client \
  python3 \
  python3-pip \
  python3-venv \
  rsync \
  sudo \
  util-linux

# OCI Ubuntu images ship with a final INPUT reject rule that otherwise blocks
# Nginx even when the VCN security list allows HTTP(S). Insert only the public
# Web ports ahead of that reject and persist the resulting IPv4 rules.
for web_port in 80 443; do
  if ! iptables -C INPUT -p tcp --dport "${web_port}" -j ACCEPT 2>/dev/null; then
    reject_line="$(
      iptables -L INPUT --line-numbers --numeric |
        awk '$2 == "REJECT" { print $1; exit }'
    )"
    if [[ -n "${reject_line}" ]]; then
      iptables -I INPUT "${reject_line}" -p tcp --dport "${web_port}" -j ACCEPT
    else
      iptables -A INPUT -p tcp --dport "${web_port}" -j ACCEPT
    fi
  fi
done
netfilter-persistent save >/dev/null

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

if ! getent group "${BUILD_GROUP}" >/dev/null; then
  groupadd --system "${BUILD_GROUP}"
fi

if ! id --user "${BUILD_USER}" >/dev/null 2>&1; then
  useradd \
    --system \
    --gid "${BUILD_GROUP}" \
    --home-dir /nonexistent \
    --no-create-home \
    --shell /usr/sbin/nologin \
    "${BUILD_USER}"
fi
# This account exists only for candidate builds. Normalize an existing account
# rather than inheriting supplementary groups or an interactive shell.
usermod \
  --gid "${BUILD_GROUP}" \
  --groups '' \
  --home /nonexistent \
  --shell /usr/sbin/nologin \
  "${BUILD_USER}"
[[ "$(id --user "${BUILD_USER}")" != 0 ]] || fail "build account must not be root"
[[ "$(id --user "${BUILD_USER}")" != "$(id --user "${SERVICE_USER}")" ]] || \
  fail "build and service accounts must be distinct"
[[ "$(id --group "${BUILD_USER}")" != "$(id --group "${SERVICE_USER}")" ]] || \
  fail "build and service groups must be distinct"
[[ "$(id --group --name "${BUILD_USER}")" == "${BUILD_GROUP}" ]] || \
  fail "build account must use its dedicated primary group"
[[ "$(id --groups --name "${BUILD_USER}")" == "${BUILD_GROUP}" ]] || \
  fail "build account must not have supplementary groups"
[[ "$(getent passwd "${BUILD_USER}")" == *:/usr/sbin/nologin ]] || \
  fail "build account must have a non-login shell"

if ! getent group "${DEPLOY_GROUP}" >/dev/null; then
  groupadd --system "${DEPLOY_GROUP}"
fi

install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 \
  "${DEPLOY_DIR}/scripts/deploy-transport.sh" \
  "${DEPLOY_TRANSPORT}"

if ! id --user "${DEPLOY_USER}" >/dev/null 2>&1; then
  useradd \
    --gid "${DEPLOY_GROUP}" \
    --home-dir "${DEPLOY_HOME}" \
    --create-home \
    --shell "${DEPLOY_TRANSPORT}" \
    "${DEPLOY_USER}"
fi
# The transport account may authenticate only with its dedicated SSH key. Strip
# any inherited OCI admin/sudo groups on every setup run and keep its password
# locked without disabling public-key SSH login.
usermod \
  --gid "${DEPLOY_GROUP}" \
  --groups '' \
  --home "${DEPLOY_HOME}" \
  --shell "${DEPLOY_TRANSPORT}" \
  "${DEPLOY_USER}"
passwd --lock "${DEPLOY_USER}" >/dev/null
[[ "$(id --user "${DEPLOY_USER}")" != 0 ]] || fail "deploy account must not be root"
[[ "$(id --group --name "${DEPLOY_USER}")" == "${DEPLOY_GROUP}" ]] || \
  fail "deploy account must use its dedicated primary group"
[[ "$(id --groups --name "${DEPLOY_USER}")" == "${DEPLOY_GROUP}" ]] || \
  fail "deploy account must not have supplementary groups"
[[ "$(getent passwd "${DEPLOY_USER}")" == *:"${DEPLOY_HOME}":"${DEPLOY_TRANSPORT}" ]] || \
  fail "deploy account must use its fixed home and transport shell"
[[ "$(passwd --status "${DEPLOY_USER}" | awk '{print $2}')" == L ]] || \
  fail "deploy account password must be locked"

[[ ! -L "${DEPLOY_HOME}" ]] || fail "deploy home must not be a symlink"
[[ ! -L "${DEPLOY_HOME}/.ssh" ]] || fail "deploy SSH directory must not be a symlink"
[[ ! -L "${DEPLOY_STAGING_ROOT}" ]] || fail "deploy staging path must not be a symlink"
install -d -o root -g "${DEPLOY_GROUP}" -m 0750 "${DEPLOY_HOME}"
install -d -o root -g root -m 0755 "${DEPLOY_HOME}/.ssh"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_GROUP}" -m 0700 \
  "${DEPLOY_STAGING_ROOT}"
if [[ -L "${DEPLOY_AUTHORIZED_KEYS}" ]]; then
  unlink "${DEPLOY_AUTHORIZED_KEYS}"
  install -o root -g "${DEPLOY_GROUP}" -m 0640 /dev/null "${DEPLOY_AUTHORIZED_KEYS}"
  fail "symlinked deploy authorized_keys was disabled; install the exact restricted key record"
elif [[ ! -e "${DEPLOY_AUTHORIZED_KEYS}" ]]; then
  install -o root -g "${DEPLOY_GROUP}" -m 0640 /dev/null "${DEPLOY_AUTHORIZED_KEYS}"
elif [[ -f "${DEPLOY_AUTHORIZED_KEYS}" ]]; then
  chown root:"${DEPLOY_GROUP}" "${DEPLOY_AUTHORIZED_KEYS}"
  chmod 0640 "${DEPLOY_AUTHORIZED_KEYS}"
else
  fail "deploy authorized_keys must be a regular, non-symlink file"
fi
[[ "$(stat --format='%u:%g:%a' -- "${DEPLOY_HOME}")" == \
   "0:$(id --group "${DEPLOY_USER}"):750" ]] || \
  fail "deploy home must be root-owned and mode 0750"
[[ "$(stat --format='%u:%g:%a' -- "${DEPLOY_HOME}/.ssh")" == "0:0:755" ]] || \
  fail "deploy SSH directory must be root:root mode 0755"
[[ "$(stat --format='%u:%g:%a' -- "${DEPLOY_AUTHORIZED_KEYS}")" == \
   "0:$(id --group "${DEPLOY_USER}"):640" ]] || \
  fail "deploy authorized_keys must be root-owned, deploy-group-readable, and mode 0640"

if [[ -s "${DEPLOY_AUTHORIZED_KEYS}" ]]; then
  mapfile -t deploy_authorized_key_lines <"${DEPLOY_AUTHORIZED_KEYS}"
  if [[ "${#deploy_authorized_key_lines[@]}" -ne 1 || \
        ! "${deploy_authorized_key_lines[0]}" =~ ${DEPLOY_AUTHORIZED_KEY_REGEX} ]] || \
     ! ssh-keygen -l -f "${DEPLOY_AUTHORIZED_KEYS}" >/dev/null 2>&1; then
    invalid_authorized_keys="$(mktemp "${DEPLOY_HOME}/.ssh/.authorized_keys.XXXXXX")"
    trap 'rm -f -- "${invalid_authorized_keys}"' EXIT
    chown root:"${DEPLOY_GROUP}" "${invalid_authorized_keys}"
    chmod 0640 "${invalid_authorized_keys}"
    mv -- "${invalid_authorized_keys}" "${DEPLOY_AUTHORIZED_KEYS}"
    trap - EXIT
    fail "malformed, multiple, or unrestricted deploy authorized_keys records were disabled"
  fi
fi

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

[[ ! -L "${ALLOWED_SIGNERS_FILE}" ]] || \
  fail "${ALLOWED_SIGNERS_FILE} must not be a symlink"
if [[ ! -e "${ALLOWED_SIGNERS_FILE}" ]]; then
  install -o root -g root -m 0600 /dev/null "${ALLOWED_SIGNERS_FILE}"
  printf 'Created empty %s; install the dedicated release-signing public key before deployment.\n' \
    "${ALLOWED_SIGNERS_FILE}"
elif [[ -f "${ALLOWED_SIGNERS_FILE}" && ! -L "${ALLOWED_SIGNERS_FILE}" ]]; then
  chown root:root "${ALLOWED_SIGNERS_FILE}"
  chmod 0600 "${ALLOWED_SIGNERS_FILE}"
  printf 'Preserved existing %s.\n' "${ALLOWED_SIGNERS_FILE}"
else
  fail "${ALLOWED_SIGNERS_FILE} must be a regular, non-symlink file"
fi

[[ ! -L "${RELEASE_HIGH_WATER_FILE}" ]] || \
  fail "${RELEASE_HIGH_WATER_FILE} must not be a symlink"
if [[ ! -e "${RELEASE_HIGH_WATER_FILE}" ]]; then
  high_water_temporary="$(mktemp "${CONFIG_ROOT}/.release-high-water.XXXXXX")"
  trap 'rm -f -- "${high_water_temporary}"' EXIT
  printf '%s\n' \
    'schema=finguard-release-metadata-v1' \
    'sequence=0' \
    'commit=0000000000000000000000000000000000000000' >"${high_water_temporary}"
  chown root:root "${high_water_temporary}"
  chmod 0600 "${high_water_temporary}"
  mv -- "${high_water_temporary}" "${RELEASE_HIGH_WATER_FILE}"
  trap - EXIT
  printf 'Created %s with the initial release sequence.\n' "${RELEASE_HIGH_WATER_FILE}"
elif [[ -f "${RELEASE_HIGH_WATER_FILE}" && ! -L "${RELEASE_HIGH_WATER_FILE}" ]]; then
  chown root:root "${RELEASE_HIGH_WATER_FILE}"
  chmod 0600 "${RELEASE_HIGH_WATER_FILE}"
  printf 'Preserved existing %s.\n' "${RELEASE_HIGH_WATER_FILE}"
else
  fail "${RELEASE_HIGH_WATER_FILE} must be a regular, non-symlink file"
fi

[[ ! -L "${RELEASE_HIGH_WATER_LOCK}" ]] || \
  fail "${RELEASE_HIGH_WATER_LOCK} must not be a symlink"
if [[ ! -e "${RELEASE_HIGH_WATER_LOCK}" ]]; then
  install -o root -g root -m 0600 /dev/null "${RELEASE_HIGH_WATER_LOCK}"
elif [[ -f "${RELEASE_HIGH_WATER_LOCK}" && ! -L "${RELEASE_HIGH_WATER_LOCK}" ]]; then
  chown root:root "${RELEASE_HIGH_WATER_LOCK}"
  chmod 0600 "${RELEASE_HIGH_WATER_LOCK}"
else
  fail "${RELEASE_HIGH_WATER_LOCK} must be a regular, non-symlink file"
fi

install -o root -g root -m 0644 \
  "${DEPLOY_DIR}/systemd/finguard-api.service" \
  /etc/systemd/system/finguard-api.service
install -o root -g root -m 0755 \
  "${DEPLOY_DIR}/certbot/reload-nginx.sh" \
  /etc/letsencrypt/renewal-hooks/deploy/finguard-reload-nginx
install -o root -g root -m 0755 \
  "${DEPLOY_DIR}/scripts/deploy-release.sh" \
  "${DEPLOY_RUNNER}"
install -o root -g root -m 0755 \
  "${DEPLOY_DIR}/scripts/release-metadata.sh" \
  /usr/local/libexec/finguard-release-metadata

[[ ! -L "${DEPLOY_SUDOERS_FILE}" ]] || \
  fail "${DEPLOY_SUDOERS_FILE} must not be a symlink"
deploy_sudoers_temporary="$(mktemp /etc/sudoers.d/.finguard-deploy.XXXXXX)"
trap 'rm -f -- "${deploy_sudoers_temporary}"' EXIT
printf '%s\n' "${DEPLOY_SUDOERS_RULE}" >"${deploy_sudoers_temporary}"
chown root:root "${deploy_sudoers_temporary}"
chmod 0440 "${deploy_sudoers_temporary}"
visudo --check --file "${deploy_sudoers_temporary}" >/dev/null
mv -- "${deploy_sudoers_temporary}" "${DEPLOY_SUDOERS_FILE}"
trap - EXIT
[[ "$(stat --format='%u:%g:%a' -- "${DEPLOY_SUDOERS_FILE}")" == "0:0:440" ]] || \
  fail "deploy sudoers rule must be root:root mode 0440"
visudo --check --file "${DEPLOY_SUDOERS_FILE}" >/dev/null

# Refresh an activated HTTPS configuration from the current trusted template.
# Recovery is strict and the helper restores/revalidates/reloads the prior site
# on failure. A non-HTTPS site is replaced by the inert bootstrap configuration.
[[ ! -L /etc/nginx/sites-available/finguard ]] || \
  fail "Nginx site path must not be a symlink"
if [[ ! -e /etc/nginx/sites-available/finguard ]]; then
  install -o root -g root -m 0644 \
    "${DEPLOY_DIR}/nginx/finguard-http.conf" \
    /etc/nginx/sites-available/finguard
elif [[ -f /etc/nginx/sites-available/finguard ]]; then
  if grep -Eq \
    '^[[:space:]]*(listen[[:space:]]+([^;[:space:]]*:)?443([[:space:]]|;)|ssl_certificate(_key)?[[:space:]])' \
    /etc/nginx/sites-available/finguard; then
    bash "${DEPLOY_DIR}/scripts/https-config.sh" --refresh-existing
  else
    install -o root -g root -m 0644 \
      "${DEPLOY_DIR}/nginx/finguard-http.conf" \
      /etc/nginx/sites-available/finguard
  fi
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
systemctl reload nginx
systemctl enable finguard-api.service

printf '\nOCI host setup is ready. Next:\n'
printf '  Architecture detected: %s (arm64 is the intended OCI target).\n' "$(dpkg --print-architecture)"
printf '  1. Edit /etc/finguard/finguard.env.\n'
printf '     Replace the AUTH_SECRET_KEY placeholder; production startup rejects it.\n'
printf '  2. Install the dedicated finguard-ci Ed25519 public key in %s.\n' \
  "${ALLOWED_SIGNERS_FILE}"
printf '  3. Install the single restricted SSH key record in %s.\n' \
  "${DEPLOY_AUTHORIZED_KEYS}"
printf '  4. Point DNS at this VM.\n'
printf '  5. Run enable-https.sh to issue a certificate and activate HTTPS.\n'
printf '  6. Only then deploy and use the application through GitHub Actions.\n'
printf '  The bootstrap HTTP site exposes only ACME challenges; no API or UI is public.\n'
