#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_ROOT="/opt/finguard"
readonly BACKEND_ROOT="${APP_ROOT}/backend"
readonly WEB_ROOT="${APP_ROOT}/web"
readonly STATE_ROOT="/var/lib/finguard"
readonly ENV_FILE="/etc/finguard/finguard.env"
readonly UNIT_PATH="/etc/systemd/system/finguard-api.service"
readonly SERVICE_NAME="finguard-api.service"
readonly HEALTHCHECK_URL="http://127.0.0.1:8000/api/v1/health"

fail() {
  printf 'deploy-release: %s\n' "$*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run this script with sudo"
[[ $# -eq 1 ]] || fail "usage: $0 RELEASE_ARCHIVE"

readonly ARCHIVE="$1"
[[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" ]] || fail "release archive is not a regular file"
[[ -f "${ENV_FILE}" ]] || fail "production environment file is missing"
[[ -f "${UNIT_PATH}" ]] || fail "systemd unit is missing; run setup-oci.sh first"
id --user finguard >/dev/null 2>&1 || fail "service account is missing; run setup-oci.sh first"

for required_command in cmp curl find nginx python3 rsync stat systemctl tar; do
  command -v "${required_command}" >/dev/null || fail "${required_command} is not installed"
done

install -d -o root -g root -m 0755 "${APP_ROOT}"
install -d -o finguard -g finguard -m 0750 "${STATE_ROOT}"

STAGING_DIR="$(mktemp -d /tmp/finguard-release.XXXXXX)"
CANDIDATE_DIR="$(mktemp -d "${APP_ROOT}/.candidate.XXXXXX")"
PREVIOUS_DIR="$(mktemp -d "${APP_ROOT}/.previous.XXXXXX")"
readonly STAGING_DIR CANDIDATE_DIR PREVIOUS_DIR
readonly SAFE_ARCHIVE="${STAGING_DIR}/release.tgz"

activation_started=false
activation_succeeded=false

rollback() {
  printf 'deploy-release: restoring the previous release\n' >&2
  systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true

  if [[ -d "${PREVIOUS_DIR}/backend" && ! -L "${PREVIOUS_DIR}/backend" ]]; then
    if [[ -e "${BACKEND_ROOT}" || -L "${BACKEND_ROOT}" ]]; then
      mv -- "${BACKEND_ROOT}" "${CANDIDATE_DIR}/failed-backend"
    fi
    mv -- "${PREVIOUS_DIR}/backend" "${BACKEND_ROOT}"
  fi

  if [[ -d "${PREVIOUS_DIR}/web" && ! -L "${PREVIOUS_DIR}/web" ]]; then
    if [[ -e "${WEB_ROOT}" || -L "${WEB_ROOT}" ]]; then
      mv -- "${WEB_ROOT}" "${CANDIDATE_DIR}/failed-web"
    fi
    mv -- "${PREVIOUS_DIR}/web" "${WEB_ROOT}"
  fi

  systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE_NAME}" || true
  nginx -t && systemctl reload nginx || true
}

cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e

  if [[ "${activation_started}" == true && "${activation_succeeded}" != true ]]; then
    rollback
    exit_status=1
  fi

  if [[ "${STAGING_DIR}" == /tmp/finguard-release.* && -d "${STAGING_DIR}" && ! -L "${STAGING_DIR}" ]]; then
    rm -rf -- "${STAGING_DIR}"
  fi
  if [[ "${CANDIDATE_DIR}" == "${APP_ROOT}"/.candidate.* && -d "${CANDIDATE_DIR}" && ! -L "${CANDIDATE_DIR}" ]]; then
    rm -rf -- "${CANDIDATE_DIR}"
  fi
  if [[ "${PREVIOUS_DIR}" == "${APP_ROOT}"/.previous.* && -d "${PREVIOUS_DIR}" && ! -L "${PREVIOUS_DIR}" ]]; then
    rm -rf -- "${PREVIOUS_DIR}"
  fi

  exit "${exit_status}"
}
trap cleanup EXIT

archive_size="$(stat --format='%s' -- "${ARCHIVE}")"
(( archive_size > 0 && archive_size <= 268435456 )) || \
  fail "release archive must be between 1 byte and 256 MiB"
install -o root -g root -m 0600 -- "${ARCHIVE}" "${SAFE_ARCHIVE}"

# The release comes from CI, but reject paths and entry types that could escape
# the staging directory if the archive were replaced while in transit.
tar --list --gzip --file "${SAFE_ARCHIVE}" >"${STAGING_DIR}/archive-paths.txt"
if grep -E '(^/|(^|/)\.\.(/|$))' "${STAGING_DIR}/archive-paths.txt" >/dev/null; then
  fail "release archive contains an unsafe path"
fi

tar --list --verbose --gzip --file "${SAFE_ARCHIVE}" >"${STAGING_DIR}/archive-entries.txt"
if awk 'substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { found = 1 } END { exit found ? 0 : 1 }' \
  "${STAGING_DIR}/archive-entries.txt"; then
  fail "release archive may contain only regular files and directories"
fi
if ! awk '{ bytes += $3; entries += 1 } END { exit bytes <= 536870912 && entries <= 20000 ? 0 : 1 }' \
  "${STAGING_DIR}/archive-entries.txt"; then
  fail "release archive expands beyond the 512 MiB or 20,000-entry safety limit"
fi

tar --extract --gzip --file "${SAFE_ARCHIVE}" --directory "${STAGING_DIR}" \
  --no-same-owner --no-same-permissions

[[ -f "${STAGING_DIR}/backend/app/main.py" ]] || fail "release has no FastAPI application"
[[ -f "${STAGING_DIR}/backend/pyproject.toml" ]] || fail "release has no backend package metadata"
[[ -f "${STAGING_DIR}/web/index.html" ]] || fail "release has no Flutter web build"
[[ -f "${STAGING_DIR}/deploy/systemd/finguard-api.service" ]] || fail "release has no systemd unit"
bash -n "${STAGING_DIR}/deploy/scripts/"*.sh "${STAGING_DIR}/deploy/certbot/"*.sh
cmp --silent "${STAGING_DIR}/deploy/systemd/finguard-api.service" "${UNIT_PATH}" || \
  fail "release systemd unit differs from the installed unit; rerun setup-oci.sh"
cmp --silent \
  "${STAGING_DIR}/deploy/scripts/deploy-release.sh" \
  /usr/local/sbin/finguard-deploy-release || \
  fail "release runner differs from the installed runner; rerun setup-oci.sh"

install -d -o root -g finguard -m 0750 "${CANDIDATE_DIR}/backend"
install -d -o root -g www-data -m 0755 "${CANDIDATE_DIR}/web"
rsync --archive --delete \
  --exclude='.venv/' \
  --exclude='.env' \
  --exclude='*.db' \
  "${STAGING_DIR}/backend/" "${CANDIDATE_DIR}/backend/"
rsync --archive --delete "${STAGING_DIR}/web/" "${CANDIDATE_DIR}/web/"

# Build the new environment before stopping the live service. apt and pip use
# native arm64 packages on the target; no container runtime or emulation is used.
python3 -m venv "${CANDIDATE_DIR}/backend/.venv"
PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_INPUT=1 \
  "${CANDIDATE_DIR}/backend/.venv/bin/python" -m pip install \
  --no-cache-dir \
  --upgrade \
  "${CANDIDATE_DIR}/backend"
"${CANDIDATE_DIR}/backend/.venv/bin/python" -m pip check
"${CANDIDATE_DIR}/backend/.venv/bin/python" -m compileall -q \
  "${CANDIDATE_DIR}/backend/app"

(
  cd -- "${CANDIDATE_DIR}/backend"
  APP_ENV=production \
    DATABASE_URL=sqlite:////var/lib/finguard/finguard.db \
    ALLOWED_ORIGINS=https://example.invalid \
    AUTH_SECRET_KEY=deployment-validation-only-secret-key-32 \
    ENABLE_AI_CONTEXT=false \
    .venv/bin/python -c 'from app.main import app; assert app is not None'
)

chown -R root:finguard "${CANDIDATE_DIR}/backend"
chown -R root:www-data "${CANDIDATE_DIR}/web"
chmod -R a-s,go-w "${CANDIDATE_DIR}/backend" "${CANDIDATE_DIR}/web"
chmod 0750 "${CANDIDATE_DIR}/backend"
find "${CANDIDATE_DIR}/web" -type d -exec chmod 0755 {} +
find "${CANDIDATE_DIR}/web" -type f -exec chmod 0644 {} +

[[ -d "${BACKEND_ROOT}" && ! -L "${BACKEND_ROOT}" ]] || \
  fail "backend path is not a regular directory"
[[ -d "${WEB_ROOT}" && ! -L "${WEB_ROOT}" ]] || \
  fail "web path is not a regular directory"
nginx -t

activation_started=true
systemctl stop "${SERVICE_NAME}"
mv -- "${BACKEND_ROOT}" "${PREVIOUS_DIR}/backend"
mv -- "${WEB_ROOT}" "${PREVIOUS_DIR}/web"
mv -- "${CANDIDATE_DIR}/backend" "${BACKEND_ROOT}"
mv -- "${CANDIDATE_DIR}/web" "${WEB_ROOT}"

systemctl reset-failed "${SERVICE_NAME}" >/dev/null 2>&1 || true
systemctl restart "${SERVICE_NAME}"

healthy=false
for _attempt in {1..20}; do
  if health_response="$(curl --fail --silent --max-time 3 "${HEALTHCHECK_URL}")" && \
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"${health_response}"; then
    healthy=true
    break
  fi
  sleep 2
done

if [[ "${healthy}" != true ]]; then
  systemctl status "${SERVICE_NAME}" --no-pager || true
  journalctl --unit "${SERVICE_NAME}" --lines 50 --no-pager || true
  fail "API and database health check failed after deployment"
fi

nginx -t
systemctl reload nginx
activation_succeeded=true

printf 'FinGuard deployment completed and the API/database health check passed.\n'
