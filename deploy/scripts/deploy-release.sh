#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_ROOT="/opt/finguard"
readonly BACKEND_ROOT="${APP_ROOT}/backend"
readonly WEB_ROOT="${APP_ROOT}/web"
readonly STATE_ROOT="/var/lib/finguard"
readonly CONFIG_ROOT="/etc/finguard"
readonly ENV_FILE="/etc/finguard/finguard.env"
readonly ALLOWED_SIGNERS_FILE="/etc/finguard/release_allowed_signers"
readonly RELEASE_HIGH_WATER_FILE="${CONFIG_ROOT}/release_high_water"
readonly RELEASE_HIGH_WATER_LOCK="${CONFIG_ROOT}/release_high_water.lock"
readonly RELEASE_METADATA_TOOL="/usr/local/libexec/finguard-release-metadata"
readonly RELEASE_SIGNER_IDENTITY="finguard-ci"
readonly RELEASE_SIGNATURE_NAMESPACE="finguard-release"
readonly SERVICE_USER="finguard"
readonly SERVICE_GROUP="finguard"
readonly BUILD_USER="finguard-build"
readonly BUILD_GROUP="finguard-build"
readonly DEPLOY_USER="finguard-deploy"
readonly DEPLOY_STAGING_ROOT="/home/finguard-deploy/finguard-deploy"
readonly INSTALLED_RUNNER="/usr/local/sbin/finguard-deploy-release"
readonly UNIT_PATH="/etc/systemd/system/finguard-api.service"
readonly SERVICE_NAME="finguard-api.service"
readonly HEALTHCHECK_URL="http://127.0.0.1:8000/api/v1/health"
readonly AUTHORIZED_MAIN_URL="https://api.github.com/repos/Black-and-Yellow/pec/git/ref/heads/main"

fail() {
  printf 'deploy-release: %s\n' "$*" >&2
  exit 1
}

require_amd64_host() {
  local dpkg_architecture
  local machine_architecture

  command -v dpkg >/dev/null || fail "dpkg is not installed"
  command -v uname >/dev/null || fail "uname is not installed"
  dpkg_architecture="$(dpkg --print-architecture)" || \
    fail "unable to determine the Debian host architecture"
  machine_architecture="$(uname -m)" || \
    fail "unable to determine the kernel host architecture"
  [[ "${dpkg_architecture}" == "amd64" && "${machine_architecture}" == "x86_64" ]] || \
    fail "unsupported host architecture; expected Ubuntu amd64/x86_64"
}

check_authoritative_main_response() {
  [[ $# -eq 2 ]] || return 1
  local expected_commit="$1"
  local response_path="$2"
  local authoritative_commit

  [[ "${expected_commit}" =~ ^[0-9a-f]{40}$ ]] || return 1
  [[ -f "${response_path}" && ! -L "${response_path}" ]] || return 1
  authoritative_commit="$(python3 - "${response_path}" <<'PY'
import json
import re
import sys


def reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def reject_nonstandard_number(value: str) -> None:
    raise ValueError(f"invalid JSON number: {value}")


try:
    with open(sys.argv[1], "r", encoding="utf-8") as response_file:
        response = json.load(
            response_file,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonstandard_number,
        )
    if type(response) is not dict or response.get("ref") != "refs/heads/main":
        raise ValueError("unexpected ref response")
    target = response.get("object")
    if type(target) is not dict or target.get("type") != "commit":
        raise ValueError("unexpected ref target")
    commit = target.get("sha")
    if type(commit) is not str or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("invalid commit")
except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
    raise SystemExit(1)

sys.stdout.write(commit)
PY
)" || return 1
  [[ "${authoritative_commit}" == "${expected_commit}" ]]
}

if [[ $# -eq 2 ]]; then
  readonly RELEASE_MODE="forward"
elif [[ $# -eq 3 && "$3" == "--allow-rollback" ]]; then
  readonly RELEASE_MODE="rollback"
else
  fail "usage: $0 RELEASE_ARCHIVE RELEASE_SIGNATURE [--allow-rollback]"
fi
readonly ARCHIVE="$1"
readonly SIGNATURE="$2"

if [[ "${RELEASE_MODE}" == "forward" ]]; then
  readonly EXPECTED_FORWARD_COMMAND="${INSTALLED_RUNNER} ${DEPLOY_STAGING_ROOT}/finguard-release.tgz ${DEPLOY_STAGING_ROOT}/finguard-release.tgz.sig"
  [[ "$0" == "${INSTALLED_RUNNER}" ]] || \
    fail "forward deployment must use the installed release runner"
  [[ "${SUDO_USER:-}" == "${DEPLOY_USER}" ]] || \
    fail "forward deployment requires the dedicated transport account"
  [[ "${ARCHIVE}" == "${DEPLOY_STAGING_ROOT}/finguard-release.tgz" && \
     "${SIGNATURE}" == "${DEPLOY_STAGING_ROOT}/finguard-release.tgz.sig" ]] || \
    fail "forward deployment requires the fixed staging paths"
  [[ "${SUDO_COMMAND:-}" == "${EXPECTED_FORWARD_COMMAND}" ]] || \
    fail "forward deployment command does not match the authorized sudo command"
elif [[ "${SUDO_USER:-}" == "${DEPLOY_USER}" ]]; then
  fail "the transport account is not authorized to roll back releases"
fi

[[ ${EUID} -eq 0 ]] || fail "run this script with sudo"
require_amd64_host
if [[ "${RELEASE_MODE}" == "forward" ]]; then
  [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] || fail "forward deployment has no valid sudo UID"
  [[ "${SUDO_UID}" == "$(id --user "${DEPLOY_USER}")" ]] || \
    fail "forward deployment sudo identity does not match the transport account"
fi
umask 0077

[[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" ]] || fail "release archive is not a regular file"
[[ -f "${SIGNATURE}" && ! -L "${SIGNATURE}" ]] || fail "release signature is not a regular file"
[[ -f "${ENV_FILE}" ]] || fail "production environment file is missing"
if grep -Eq "^[[:space:]]*AUTH_SECRET_KEY[[:space:]]*=[[:space:]]*['\"]?replace-with-at-least-32-random-characters['\"]?[[:space:]]*$" \
  "${ENV_FILE}"; then
  fail "production AUTH_SECRET_KEY must replace the documented placeholder"
fi
[[ -f "${UNIT_PATH}" ]] || fail "systemd unit is missing; run setup-oci.sh first"
[[ -x "${RELEASE_METADATA_TOOL}" && ! -L "${RELEASE_METADATA_TOOL}" ]] || \
  fail "release metadata validator is missing; run setup-oci.sh first"
[[ -f "${RELEASE_HIGH_WATER_LOCK}" && ! -L "${RELEASE_HIGH_WATER_LOCK}" ]] || \
  fail "release high-water lock must be a regular, non-symlink file"
[[ "$(stat --format='%u:%g:%a' -- "${RELEASE_HIGH_WATER_LOCK}")" == "0:0:600" ]] || \
  fail "release high-water lock must be root:root mode 0600"
[[ -f "${ALLOWED_SIGNERS_FILE}" && ! -L "${ALLOWED_SIGNERS_FILE}" ]] || \
  fail "release allowed-signers file must be a regular, non-symlink file"
[[ "$(stat --format='%u:%g:%a' -- "${ALLOWED_SIGNERS_FILE}")" == "0:0:600" ]] || \
  fail "release allowed-signers file must be root:root mode 0600"
awk 'NF != 3 || $1 != "finguard-ci" || $2 != "ssh-ed25519" { invalid = 1 } END { exit !(NR == 1 && !invalid) }' \
  "${ALLOWED_SIGNERS_FILE}" || \
  fail "release allowed-signers file must contain exactly one finguard-ci Ed25519 public key"
id --user "${SERVICE_USER}" >/dev/null 2>&1 || \
  fail "service account is missing; run setup-oci.sh first"
id --user "${BUILD_USER}" >/dev/null 2>&1 || \
  fail "build account is missing; run setup-oci.sh first"
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

for required_command in awk cmp curl env find flock grep nginx python3 rsync runuser sha256sum ssh-keygen stat systemctl tar; do
  command -v "${required_command}" >/dev/null || fail "${required_command} is not installed"
done

exec 9<>"${RELEASE_HIGH_WATER_LOCK}"
flock --exclusive 9

install -d -o root -g root -m 0755 "${APP_ROOT}"
install -d -o "${SERVICE_USER}" -g "${SERVICE_GROUP}" -m 0750 "${STATE_ROOT}"

for protected_path in "${CONFIG_ROOT}" "${ENV_FILE}" "${STATE_ROOT}" "${BACKEND_ROOT}"; do
  if runuser --user "${BUILD_USER}" -- test -r "${protected_path}" || \
    runuser --user "${BUILD_USER}" -- test -x "${protected_path}"; then
    fail "build account must not access ${protected_path}"
  fi
done

STAGING_DIR="$(mktemp -d /tmp/finguard-release.XXXXXX)"
CANDIDATE_DIR="$(mktemp -d "${APP_ROOT}/.candidate.XXXXXX")"
PREVIOUS_DIR="$(mktemp -d "${APP_ROOT}/.previous.XXXXXX")"
readonly STAGING_DIR CANDIDATE_DIR PREVIOUS_DIR
readonly SAFE_ARCHIVE="${STAGING_DIR}/release.tgz"
readonly SAFE_SIGNATURE="${STAGING_DIR}/release.tgz.sig"
readonly SIGNED_RELEASE_METADATA="${STAGING_DIR}/release-metadata"
readonly AUTHORIZED_MAIN_RESPONSE="${STAGING_DIR}/authorized-main.json"
readonly SIGNED_WHEELHOUSE_ROOT="${STAGING_DIR}/python-wheelhouse"
readonly VALIDATION_ROOT="${CANDIDATE_DIR}/.validation"
readonly BUILD_SOURCE_ROOT="${VALIDATION_ROOT}/backend-source"
readonly OFFLINE_WHEELHOUSE_ROOT="${VALIDATION_ROOT}/python-wheelhouse"
readonly VALIDATION_DB="${VALIDATION_ROOT}/finguard-validation.db"
readonly VENV_PYTHON="${CANDIDATE_DIR}/backend/.venv/bin/python"
declare -ar IMPORT_VALIDATION_ENV=(
  APP_ENV=production
  "DATABASE_URL=sqlite:///${VALIDATION_DB}"
  ALLOWED_ORIGINS=https://example.invalid
  AUTH_SECRET_KEY=deployment-validation-only-secret-key-32
  ENABLE_AI_CONTEXT=false
  GEMINI_API_KEY=
  GOOGLE_OAUTH_CLIENT_IDS=
)

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
signature_size="$(stat --format='%s' -- "${SIGNATURE}")"
(( signature_size > 0 && signature_size <= 16384 )) || \
  fail "release signature must be between 1 byte and 16 KiB"
install -o root -g root -m 0600 -- "${ARCHIVE}" "${SAFE_ARCHIVE}"
install -o root -g root -m 0600 -- "${SIGNATURE}" "${SAFE_SIGNATURE}"
archive_size="$(stat --format='%s' -- "${SAFE_ARCHIVE}")"
(( archive_size > 0 && archive_size <= 268435456 )) || \
  fail "root-copied release archive must be between 1 byte and 256 MiB"
signature_size="$(stat --format='%s' -- "${SAFE_SIGNATURE}")"
(( signature_size > 0 && signature_size <= 16384 )) || \
  fail "root-copied release signature must be between 1 byte and 16 KiB"
awk 'NR == 1 { first = $0 } { last = $0 } END { exit !(NR >= 3 && first == "-----BEGIN SSH SIGNATURE-----" && last == "-----END SSH SIGNATURE-----") }' \
  "${SAFE_SIGNATURE}" || fail "release signature is not an armored OpenSSH signature"

# Verify the root-owned copies before archive listing, extraction, or execution.
# The SSH transport account cannot forge this detached signature or influence
# the root-controlled signer trust file.
ssh-keygen -Y verify \
  -f "${ALLOWED_SIGNERS_FILE}" \
  -I "${RELEASE_SIGNER_IDENTITY}" \
  -n "${RELEASE_SIGNATURE_NAMESPACE}" \
  -s "${SAFE_SIGNATURE}" \
  <"${SAFE_ARCHIVE}" >/dev/null || fail "release signature verification failed"

# The signed release comes from CI, but still reject paths and entry types that
# could escape the staging directory.
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

[[ -f "${SIGNED_RELEASE_METADATA}" && ! -L "${SIGNED_RELEASE_METADATA}" ]] || \
  fail "release has no regular signed metadata"
cmp --silent \
  "${STAGING_DIR}/deploy/scripts/release-metadata.sh" \
  "${RELEASE_METADATA_TOOL}" || \
  fail "release metadata validator differs from the installed validator; rerun setup-oci.sh"
release_identity="$(
  "${RELEASE_METADATA_TOOL}" check \
    "${SIGNED_RELEASE_METADATA}" \
    "${RELEASE_HIGH_WATER_FILE}" \
    "${RELEASE_MODE}" \
    0:0
)" || fail "release metadata freshness validation failed"
read -r release_sequence release_commit release_identity_extra <<<"${release_identity}"
[[ -n "${release_sequence}" && -n "${release_commit}" && -z "${release_identity_extra:-}" ]] || \
  fail "release metadata validator returned an invalid identity"

[[ -f "${STAGING_DIR}/backend/app/main.py" ]] || fail "release has no FastAPI application"
[[ -f "${STAGING_DIR}/backend/pyproject.toml" ]] || fail "release has no backend package metadata"
[[ -f "${STAGING_DIR}/web/index.html" ]] || fail "release has no Flutter web build"
[[ -f "${STAGING_DIR}/deploy/systemd/finguard-api.service" ]] || fail "release has no systemd unit"
[[ -d "${SIGNED_WHEELHOUSE_ROOT}" && ! -L "${SIGNED_WHEELHOUSE_ROOT}" ]] || \
  fail "release has no regular amd64 Python wheelhouse directory"
[[ -f "${SIGNED_WHEELHOUSE_ROOT}/requirements.txt" && \
   ! -L "${SIGNED_WHEELHOUSE_ROOT}/requirements.txt" ]] || \
  fail "release wheelhouse has no regular requirements manifest"
[[ -f "${SIGNED_WHEELHOUSE_ROOT}/SHA256SUMS" && \
   ! -L "${SIGNED_WHEELHOUSE_ROOT}/SHA256SUMS" ]] || \
  fail "release wheelhouse has no regular checksum manifest"
grep -Fxq 'pip==26.2.1' "${SIGNED_WHEELHOUSE_ROOT}/requirements.txt" || \
  fail "release wheelhouse does not pin the deployment pip version"
grep -Fxq 'setuptools==80.9.0' "${SIGNED_WHEELHOUSE_ROOT}/requirements.txt" || \
  fail "release wheelhouse does not pin the backend build requirement"

if find "${SIGNED_WHEELHOUSE_ROOT}" -mindepth 1 -maxdepth 1 -type d -print -quit | \
  grep -q .; then
  fail "release wheelhouse may not contain nested directories"
fi

wheel_count=0
wheel_bytes=0
while IFS= read -r -d '' wheelhouse_entry; do
  wheel_name="${wheelhouse_entry##*/}"
  [[ -f "${wheelhouse_entry}" && ! -L "${wheelhouse_entry}" ]] || \
    fail "release wheelhouse entries must be regular, non-symlink files"
  case "${wheel_name}" in
    requirements.txt|SHA256SUMS)
      ;;
    *.whl)
      [[ "${wheel_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.whl$ ]] || \
        fail "release wheelhouse contains an invalid wheel filename"
      wheel_size="$(stat --format='%s' -- "${wheelhouse_entry}")"
      (( wheel_size > 0 && wheel_size <= 104857600 )) || \
        fail "release wheelhouse contains an empty or oversized wheel"
      (( wheel_count += 1 ))
      (( wheel_bytes += wheel_size ))
      ;;
    *)
      fail "release wheelhouse contains an unexpected file"
      ;;
  esac
done < <(find "${SIGNED_WHEELHOUSE_ROOT}" -mindepth 1 -maxdepth 1 -print0)
(( wheel_count >= 13 && wheel_count <= 128 )) || \
  fail "release wheelhouse contains an invalid wheel count"
(( wheel_bytes <= 268435456 )) || fail "release wheelhouse exceeds 256 MiB"

awk '
  NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ ||
    $2 !~ /^[A-Za-z0-9][A-Za-z0-9._+-]*\.whl$/ { invalid = 1 }
  { names[$2] += 1 }
  END {
    for (name in names) {
      if (names[name] != 1) {
        invalid = 1
      }
    }
    exit invalid ? 1 : 0
  }
' "${SIGNED_WHEELHOUSE_ROOT}/SHA256SUMS" || \
  fail "release wheelhouse checksum manifest is invalid"
manifest_count="$(awk 'END { print NR + 0 }' "${SIGNED_WHEELHOUSE_ROOT}/SHA256SUMS")"
(( manifest_count == wheel_count )) || \
  fail "release wheelhouse checksum manifest does not cover every wheel"
(
  cd -- "${SIGNED_WHEELHOUSE_ROOT}"
  sha256sum --check --strict SHA256SUMS
) || fail "release wheelhouse checksum verification failed"

bash -n "${STAGING_DIR}/deploy/scripts/"*.sh "${STAGING_DIR}/deploy/certbot/"*.sh
cmp --silent "${STAGING_DIR}/deploy/systemd/finguard-api.service" "${UNIT_PATH}" || \
  fail "release systemd unit differs from the installed unit; rerun setup-oci.sh"
cmp --silent \
  "${STAGING_DIR}/deploy/scripts/deploy-release.sh" \
  /usr/local/sbin/finguard-deploy-release || \
  fail "release runner differs from the installed runner; rerun setup-oci.sh"

chown root:"${BUILD_GROUP}" "${CANDIDATE_DIR}"
chmod 0710 "${CANDIDATE_DIR}"
install -d -o root -g "${BUILD_GROUP}" -m 0750 "${CANDIDATE_DIR}/backend"
install -d -o root -g root -m 0700 "${CANDIDATE_DIR}/web"
rsync --archive --delete \
  --exclude='.venv/' \
  --exclude='.env' \
  --exclude='*.db' \
  "${STAGING_DIR}/backend/" "${CANDIDATE_DIR}/backend/"
rsync --archive --delete "${STAGING_DIR}/web/" "${CANDIDATE_DIR}/web/"
chown -R --no-dereference root:"${BUILD_GROUP}" "${CANDIDATE_DIR}/backend"
chmod -R u=rwX,g=rX,o= "${CANDIDATE_DIR}/backend"
install -d -o root -g "${BUILD_GROUP}" -m 0750 "${VALIDATION_ROOT}"
install -d -o "${BUILD_USER}" -g "${BUILD_GROUP}" -m 0700 \
  "${BUILD_SOURCE_ROOT}" \
  "${VALIDATION_ROOT}/home" \
  "${VALIDATION_ROOT}/pip-cache" \
  "${VALIDATION_ROOT}/tmp"
rsync --archive --delete \
  --exclude='.validation/' \
  --exclude='.venv/' \
  "${CANDIDATE_DIR}/backend/" "${BUILD_SOURCE_ROOT}/"
chown -R --no-dereference "${BUILD_USER}:${BUILD_GROUP}" "${BUILD_SOURCE_ROOT}"
chmod -R u=rwX,g=,o= "${BUILD_SOURCE_ROOT}"
install -d -o root -g "${BUILD_GROUP}" -m 0750 "${OFFLINE_WHEELHOUSE_ROOT}"
rsync --archive --delete \
  "${SIGNED_WHEELHOUSE_ROOT}/" "${OFFLINE_WHEELHOUSE_ROOT}/"
chown -R --no-dereference root:"${BUILD_GROUP}" "${OFFLINE_WHEELHOUSE_ROOT}"
find "${OFFLINE_WHEELHOUSE_ROOT}" -type d -exec chmod 0750 {} +
find "${OFFLINE_WHEELHOUSE_ROOT}" -type f -exec chmod 0640 {} +
(
  cd -- "${OFFLINE_WHEELHOUSE_ROOT}"
  sha256sum --check --strict SHA256SUMS >/dev/null
) || fail "root-owned wheelhouse copy failed checksum verification"
if ! runuser --user "${BUILD_USER}" -- test -r \
  "${OFFLINE_WHEELHOUSE_ROOT}/requirements.txt"; then
  fail "build account cannot read the signed wheelhouse copy"
fi
if runuser --user "${BUILD_USER}" -- test -w "${OFFLINE_WHEELHOUSE_ROOT}"; then
  fail "build account must not be able to modify the signed wheelhouse copy"
fi
install -d -o "${BUILD_USER}" -g "${BUILD_GROUP}" -m 0700 \
  "${CANDIDATE_DIR}/backend/.venv"

run_as_build() (
  local build_working_directory="$1"
  shift
  cd -- "${build_working_directory}"
  runuser --user "${BUILD_USER}" -- env -i \
    HOME="${VALIDATION_ROOT}/home" \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PIP_CACHE_DIR="${VALIDATION_ROOT}/pip-cache" \
    PIP_CONFIG_FILE=/dev/null \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_FIND_LINKS="${OFFLINE_WHEELHOUSE_ROOT}" \
    PIP_NO_INPUT=1 \
    PIP_NO_INDEX=1 \
    PIP_ONLY_BINARY=:all: \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONNOUSERSITE=1 \
    PYTHONPYCACHEPREFIX="${VALIDATION_ROOT}/pycache" \
    TMPDIR="${VALIDATION_ROOT}/tmp" \
    XDG_CACHE_HOME="${VALIDATION_ROOT}/pip-cache" \
    "$@"
)

# Build the new environment before stopping the live service. PEP 517 backends
# may write package metadata beside their input, so pip receives only a
# disposable build-owned copy. Candidate application source remains immutable.
# All artifact-derived Python operations run as the isolated build account. The
# venv bootstrap uses ensurepip, then every dependency and PEP 517 build
# requirement comes from the signed, root-owned wheelhouse with indexes disabled.
run_as_build "${VALIDATION_ROOT}" python3 -m venv "${CANDIDATE_DIR}/backend/.venv"
run_as_build "${VALIDATION_ROOT}" "${VENV_PYTHON}" -m pip install \
  --no-cache-dir \
  --no-index \
  --find-links "${OFFLINE_WHEELHOUSE_ROOT}" \
  --only-binary=:all: \
  --upgrade pip==26.2.1
run_as_build "${VALIDATION_ROOT}" "${VENV_PYTHON}" -m pip install \
  --no-cache-dir \
  --no-index \
  --find-links "${OFFLINE_WHEELHOUSE_ROOT}" \
  --only-binary=:all: \
  --constraint "${BUILD_SOURCE_ROOT}/constraints-production.txt" \
  "${BUILD_SOURCE_ROOT}"
run_as_build "${VALIDATION_ROOT}" "${VENV_PYTHON}" -m pip check
run_as_build "${VALIDATION_ROOT}" "${VENV_PYTHON}" -m compileall -q \
  "${CANDIDATE_DIR}/backend/app"

run_as_build "${CANDIDATE_DIR}/backend" env "${IMPORT_VALIDATION_ENV[@]}" \
  "${VENV_PYTHON}" -c 'from pathlib import Path; import app.main; assert Path(app.main.__file__).resolve().is_relative_to(Path.cwd().resolve()); assert app.main.app is not None'

rm -rf -- "${VALIDATION_ROOT}"
chown -R --no-dereference root:"${SERVICE_GROUP}" "${CANDIDATE_DIR}/backend"
chown -R root:www-data "${CANDIDATE_DIR}/web"
chmod -R u=rwX,g=rX,o= "${CANDIDATE_DIR}/backend"
chmod -R u=rwX,g=rX,o=rX "${CANDIDATE_DIR}/web"
chmod 0750 "${CANDIDATE_DIR}/backend"
if runuser --user "${BUILD_USER}" -- test -r "${CANDIDATE_DIR}/backend" || \
  runuser --user "${BUILD_USER}" -- test -x "${CANDIDATE_DIR}/backend"; then
  fail "build account retained candidate backend access after validation"
fi
chown root:root "${CANDIDATE_DIR}"
chmod 0700 "${CANDIDATE_DIR}"

[[ -d "${BACKEND_ROOT}" && ! -L "${BACKEND_ROOT}" ]] || \
  fail "backend path is not a regular directory"
[[ -d "${WEB_ROOT}" && ! -L "${WEB_ROOT}" ]] || \
  fail "web path is not a regular directory"
nginx -t

if [[ "${RELEASE_MODE}" == "forward" ]]; then
  if ! IFS= read -r authorized_main_nonce </proc/sys/kernel/random/uuid; then
    fail "unable to create an authoritative-main request nonce"
  fi
  [[ "${authorized_main_nonce}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || \
    fail "authoritative-main request nonce is invalid"
  authorized_main_request_url="${AUTHORIZED_MAIN_URL}?finguard_freshness=${authorized_main_nonce}"
  install -o root -g root -m 0600 /dev/null "${AUTHORIZED_MAIN_RESPONSE}"
  if ! curl \
    --proto '=https' \
    --tlsv1.2 \
    --header 'Cache-Control: no-cache' \
    --header 'Pragma: no-cache' \
    --connect-timeout 5 \
    --max-time 10 \
    --max-filesize 1048576 \
    --fail \
    --silent \
    --show-error \
    --output "${AUTHORIZED_MAIN_RESPONSE}" \
    "${authorized_main_request_url}"; then
    fail "unable to read the current authoritative main revision"
  fi
  if ! check_authoritative_main_response "${release_commit}" "${AUTHORIZED_MAIN_RESPONSE}"; then
    fail "signed release commit is not the current authoritative main revision"
  fi
fi
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
"${RELEASE_METADATA_TOOL}" write-state \
  "${RELEASE_HIGH_WATER_FILE}" \
  "${release_sequence}" \
  "${release_commit}" \
  0:0 || fail "release high-water state update failed"
activation_succeeded=true

printf 'FinGuard deployment completed and the API/database health check passed.\n'
