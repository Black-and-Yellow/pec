#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly HELPER="${REPOSITORY_ROOT}/deploy/scripts/release-metadata.sh"
readonly DEPLOY_RUNNER="${REPOSITORY_ROOT}/deploy/scripts/deploy-release.sh"
readonly SETUP_RUNNER="${REPOSITORY_ROOT}/deploy/scripts/setup-oci.sh"
readonly DEPLOY_WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/deploy.yml"
readonly CI_WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/ci.yml"
readonly TEST_ROOT="$(mktemp -d)"
readonly TEST_OWNER="$(stat --format='%u:%g' -- "${TEST_ROOT}")"
readonly COMMIT_A="1111111111111111111111111111111111111111"
readonly COMMIT_B="2222222222222222222222222222222222222222"
readonly COMMIT_C="abcdef0123456789abcdef0123456789abcdef01"
readonly MAIN_B_REF="${COMMIT_B}"$'\trefs/heads/main'
readonly SYSTEM_NAME="$(uname -s)"

case "${SYSTEM_NAME}" in
  MINGW*|MSYS*|CYGWIN*) readonly WINDOWS_GIT_BASH=true ;;
  *) readonly WINDOWS_GIT_BASH=false ;;
esac

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

printf '%s\n' 'finguard-release-metadata-test-only' \
  >"${TEST_ROOT}/.finguard-release-metadata-test-root"

run_helper() {
  if [[ "${WINDOWS_GIT_BASH}" == true ]]; then
    FINGUARD_RELEASE_METADATA_TEST_BYPASS_FILE_SECURITY=1 \
      FINGUARD_RELEASE_METADATA_TEST_ROOT="${TEST_ROOT}" \
      bash "${HELPER}" "$@"
  else
    bash "${HELPER}" "$@"
  fi
}

write_record() {
  local path="$1"
  local sequence="$2"
  local commit="$3"

  printf 'schema=finguard-release-metadata-v1\nsequence=%s\ncommit=%s\n' \
    "${sequence}" "${commit}" >"${path}"
  chmod 0600 "${path}"
}

expect_reject() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'test-release-metadata: expected rejection: %s\n' "${label}" >&2
    exit 1
  fi
}

# Ubuntu exposes the production interpreter as python3. Some Windows Git Bash
# hosts expose only the repository's isolated Python executable, so adapt the
# local contract without weakening the production runner's fixed command.
if ! command -v python3 >/dev/null 2>&1; then
  readonly WINDOWS_TEST_PYTHON="${REPOSITORY_ROOT}/backend/.venv/Scripts/python.exe"
  [[ -x "${WINDOWS_TEST_PYTHON}" ]] || {
    printf 'test-release-metadata: no Python interpreter is available\n' >&2
    exit 1
  }
  python3() {
    "${WINDOWS_TEST_PYTHON}" "$@"
  }
fi

runner_main_check="${TEST_ROOT}/runner-main-check.sh"
sed -n '/^check_authoritative_main_response() {$/,/^}$/p' \
  "${DEPLOY_RUNNER}" >"${runner_main_check}"
# shellcheck source=/dev/null
source "${runner_main_check}"

valid_main_response="${TEST_ROOT}/valid-main.json"
printf '{"ref":"refs/heads/main","object":{"sha":"%s","type":"commit"}}\n' \
  "${COMMIT_C}" >"${valid_main_response}"
check_authoritative_main_response "${COMMIT_C}" "${valid_main_response}"
expect_reject "host authoritative-main mismatch" \
  check_authoritative_main_response "${COMMIT_A}" "${valid_main_response}"

malformed_main_response="${TEST_ROOT}/malformed-main.json"
printf '{"ref":' >"${malformed_main_response}"
expect_reject "malformed host authoritative-main JSON" \
  check_authoritative_main_response "${COMMIT_C}" "${malformed_main_response}"

missing_main_response="${TEST_ROOT}/missing-main.json"
printf '{"ref":"refs/heads/main","object":{"type":"commit"}}\n' \
  >"${missing_main_response}"
expect_reject "missing host authoritative-main SHA" \
  check_authoritative_main_response "${COMMIT_C}" "${missing_main_response}"
expect_reject "missing host authoritative-main response" \
  check_authoritative_main_response "${COMMIT_C}" "${TEST_ROOT}/absent-main.json"

duplicate_main_response="${TEST_ROOT}/duplicate-main.json"
printf '{"ref":"refs/heads/main","object":{"sha":"%s","sha":"%s","type":"commit"}}\n' \
  "${COMMIT_C}" "${COMMIT_C}" >"${duplicate_main_response}"
expect_reject "duplicate host authoritative-main SHA" \
  check_authoritative_main_response "${COMMIT_C}" "${duplicate_main_response}"

state="${TEST_ROOT}/state"
metadata="${TEST_ROOT}/metadata"
write_record "${state}" 10 "${COMMIT_A}"

# B can complete and deploy while A's CI is still running. Once main points at
# B, the independently tested A commit must be rejected even if its later
# deployment workflow has a newer anti-replay sequence.
[[ "$(run_helper check-authorized-main "${COMMIT_B}" "${MAIN_B_REF}")" == \
  "${COMMIT_B}" ]]
expect_reject "stale A after B became authorized main" \
  run_helper check-authorized-main "${COMMIT_A}" "${MAIN_B_REF}"
expect_reject "malformed tested commit" \
  run_helper check-authorized-main ABC "${MAIN_B_REF}"
expect_reject "missing authorized main record" \
  run_helper check-authorized-main "${COMMIT_B}" ""
expect_reject "wrong authorized ref name" \
  run_helper check-authorized-main "${COMMIT_B}" \
    "${COMMIT_B}"$'\trefs/heads/not-main'
expect_reject "multiple authorized main records" \
  run_helper check-authorized-main "${COMMIT_B}" \
    "${MAIN_B_REF}"$'\n'"${MAIN_B_REF}"

write_record "${metadata}" 11 "${COMMIT_B}"
[[ "$(run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}")" == \
  "11 ${COMMIT_B}" ]]

write_record "${metadata}" 10 "${COMMIT_B}"
expect_reject "equal sequence replay" \
  run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}"
expect_reject "equal sequence with rollback override" \
  run_helper check "${metadata}" "${state}" rollback "${TEST_OWNER}"

write_record "${metadata}" 9 "${COMMIT_B}"
expect_reject "forward downgrade" \
  run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}"
[[ "$(run_helper check "${metadata}" "${state}" rollback "${TEST_OWNER}")" == \
  "9 ${COMMIT_B}" ]]

# An authorized rollback never lowers the highest-ever accepted sequence.
run_helper write-state "${state}" 9 "${COMMIT_B}" "${TEST_OWNER}"
grep -Fxq 'sequence=10' "${state}"
grep -Fxq "commit=${COMMIT_A}" "${state}"
write_record "${metadata}" 10 "${COMMIT_B}"
expect_reject "forward replay after rollback" \
  run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}"
write_record "${metadata}" 11 "${COMMIT_B}"
[[ "$(run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}")" == \
  "11 ${COMMIT_B}" ]]

printf 'schema=finguard-release-metadata-v1\nsequence=09\ncommit=%s\n' \
  "${COMMIT_B}" >"${metadata}"
expect_reject "noncanonical metadata sequence" \
  run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}"
printf 'schema=finguard-release-metadata-v1\nsequence=11\ncommit=ABC\n' >"${metadata}"
expect_reject "malformed metadata commit" \
  run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}"

write_record "${metadata}" 11 "${COMMIT_B}"
printf 'not a state record\n' >"${state}"
expect_reject "malformed high-water state" \
  run_helper check "${metadata}" "${state}" forward "${TEST_OWNER}"
write_record "${state}" 10 "${COMMIT_A}"
if [[ "${WINDOWS_GIT_BASH}" == false ]]; then
  chmod 0644 "${state}"
  expect_reject "loose high-water state mode" \
    bash "${HELPER}" check "${metadata}" "${state}" forward "${TEST_OWNER}"
  chmod 0600 "${state}"
else
  expect_reject "test bypass without a contained test root" \
    env FINGUARD_RELEASE_METADATA_TEST_BYPASS_FILE_SECURITY=1 \
      FINGUARD_RELEASE_METADATA_TEST_ROOT="${TEST_ROOT}/missing" \
      bash "${HELPER}" check "${metadata}" "${state}" forward "${TEST_OWNER}"
fi

run_helper write-state "${state}" 11 "${COMMIT_B}" "${TEST_OWNER}"
grep -Fxq 'sequence=11' "${state}"
grep -Fxq "commit=${COMMIT_B}" "${state}"
if [[ "${WINDOWS_GIT_BASH}" == false ]]; then
  [[ "$(stat --format='%u:%g:%a' -- "${state}")" == "${TEST_OWNER}:600" ]]
fi

# Match the workflow's `tar --directory release .` layout: metadata extracts at
# the staging root, not under an extra release directory.
archive_source="${TEST_ROOT}/archive-source"
archive_staging="${TEST_ROOT}/archive-staging"
archive_path="${TEST_ROOT}/release.tgz"
mkdir "${archive_source}" "${archive_staging}"
write_record "${archive_source}/release-metadata" 11 "${COMMIT_B}"
tar --create --gzip --file "${archive_path}" --directory "${archive_source}" .
tar --extract --gzip --file "${archive_path}" --directory "${archive_staging}"
[[ -f "${archive_staging}/release-metadata" ]]
[[ ! -e "${archive_staging}/release/release-metadata" ]]

grep -Fq 'release/release-metadata' "${DEPLOY_WORKFLOW}"
grep -Fq 'GITHUB_RUN_NUMBER' "${DEPLOY_WORKFLOW}"
grep -Fq 'git rev-parse --verify HEAD^{commit}' "${DEPLOY_WORKFLOW}"
grep -Fq 'EXPECTED_RELEASE_COMMIT: ${{ github.event.workflow_run.head_sha || github.sha }}' \
  "${DEPLOY_WORKFLOW}"
[[ "$(grep -Fc 'git ls-remote --exit-code origin refs/heads/main' \
  "${DEPLOY_WORKFLOW}")" -eq 1 ]]
grep -Fq 'if ! authorized_main_ref="$(git ls-remote --exit-code origin refs/heads/main)"; then' \
  "${DEPLOY_WORKFLOW}"
grep -Fq "echo 'Unable to read the current authorized main revision.' >&2" \
  "${DEPLOY_WORKFLOW}"
[[ "$(grep -Fc 'verify_current_main' "${DEPLOY_WORKFLOW}")" -eq 2 ]]
grep -Fq 'bash deploy/scripts/release-metadata.sh check-authorized-main' \
  "${DEPLOY_WORKFLOW}"
grep -Fq 'readonly SIGNED_RELEASE_METADATA="${STAGING_DIR}/release-metadata"' "${DEPLOY_RUNNER}"
grep -Fq 'readonly RELEASE_HIGH_WATER_FILE="${CONFIG_ROOT}/release_high_water"' "${DEPLOY_RUNNER}"
grep -Fq 'readonly RELEASE_METADATA_TOOL="/usr/local/libexec/finguard-release-metadata"' "${DEPLOY_RUNNER}"
grep -Fq 'readonly AUTHORIZED_MAIN_URL="https://api.github.com/repos/Black-and-Yellow/pec/git/ref/heads/main"' \
  "${DEPLOY_RUNNER}"
grep -Fq 'readonly AUTHORIZED_MAIN_RESPONSE="${STAGING_DIR}/authorized-main.json"' \
  "${DEPLOY_RUNNER}"
grep -Fq 'install -o root -g root -m 0600 /dev/null "${AUTHORIZED_MAIN_RESPONSE}"' \
  "${DEPLOY_RUNNER}"
grep -Fq -- "--proto '=https'" "${DEPLOY_RUNNER}"
grep -Fq -- '--tlsv1.2' "${DEPLOY_RUNNER}"
grep -Fq 'authorized_main_nonce </proc/sys/kernel/random/uuid' "${DEPLOY_RUNNER}"
grep -Fq '?finguard_freshness=${authorized_main_nonce}' "${DEPLOY_RUNNER}"
grep -Fq -- "--header 'Cache-Control: no-cache'" "${DEPLOY_RUNNER}"
grep -Fq -- "--header 'Pragma: no-cache'" "${DEPLOY_RUNNER}"
grep -Fq -- '--connect-timeout 5' "${DEPLOY_RUNNER}"
grep -Fq -- '--max-time 10' "${DEPLOY_RUNNER}"
grep -Fq -- '--fail' "${DEPLOY_RUNNER}"
grep -Fq -- '--show-error' "${DEPLOY_RUNNER}"
grep -Fq 'if [[ $# -eq 2 ]]; then' "${DEPLOY_RUNNER}"
grep -Fq 'readonly RELEASE_MODE="forward"' "${DEPLOY_RUNNER}"
grep -Fq 'elif [[ $# -eq 3 && "$3" == "--allow-rollback" ]]; then' "${DEPLOY_RUNNER}"
[[ "$(grep -Fc 'readonly RELEASE_MODE="rollback"' "${DEPLOY_RUNNER}")" -eq 1 ]]
grep -Fq 'readonly DEPLOY_USER="finguard-deploy"' "${DEPLOY_RUNNER}"
grep -Fq 'readonly DEPLOY_STAGING_ROOT="/home/finguard-deploy/finguard-deploy"' \
  "${DEPLOY_RUNNER}"
grep -Fq 'readonly INSTALLED_RUNNER="/usr/local/sbin/finguard-deploy-release"' \
  "${DEPLOY_RUNNER}"
grep -Fq '[[ "${SUDO_USER:-}" == "${DEPLOY_USER}" ]]' "${DEPLOY_RUNNER}"
grep -Fq '[[ "${SUDO_COMMAND:-}" == "${EXPECTED_FORWARD_COMMAND}" ]]' \
  "${DEPLOY_RUNNER}"
grep -Fq '[[ "${SUDO_UID}" == "$(id --user "${DEPLOY_USER}")" ]]' \
  "${DEPLOY_RUNNER}"
rollback_output="${TEST_ROOT}/transport-rollback-output"
if env SUDO_USER=finguard-deploy SUDO_UID=12345 \
  bash "${DEPLOY_RUNNER}" \
    /home/finguard-deploy/finguard-deploy/finguard-release.tgz \
    /home/finguard-deploy/finguard-deploy/finguard-release.tgz.sig \
    --allow-rollback >"${rollback_output}" 2>&1; then
  printf 'test-release-metadata: transport identity unexpectedly exercised rollback\n' >&2
  exit 1
fi
grep -Fq 'the transport account is not authorized to roll back releases' \
  "${rollback_output}"
grep -Fq '"${RELEASE_METADATA_TOOL}" check' "${DEPLOY_RUNNER}"
grep -Fq '"${RELEASE_METADATA_TOOL}" write-state' "${DEPLOY_RUNNER}"
if grep -Fq 'FINGUARD_RELEASE_METADATA_TEST_' "${DEPLOY_RUNNER}"; then
  printf 'test-release-metadata: production runner must not enable test bypasses\n' >&2
  exit 1
fi
check_line="$(grep -nF '"${RELEASE_METADATA_TOOL}" check' "${DEPLOY_RUNNER}" | cut -d: -f1)"
execution_line="$(grep -nF 'bash -n "${STAGING_DIR}/deploy/scripts/"*.sh' "${DEPLOY_RUNNER}" | cut -d: -f1)"
write_line="$(grep -nF '"${RELEASE_METADATA_TOOL}" write-state' "${DEPLOY_RUNNER}" | cut -d: -f1)"
nginx_reload_line="$(grep -nF 'systemctl reload nginx' "${DEPLOY_RUNNER}" | tail -n 1 | cut -d: -f1)"
host_main_check_line="$(grep -nF 'if ! check_authoritative_main_response "${release_commit}" "${AUTHORIZED_MAIN_RESPONSE}"; then' \
  "${DEPLOY_RUNNER}" | cut -d: -f1)"
activation_started_line="$(grep -nFx 'activation_started=true' "${DEPLOY_RUNNER}" | cut -d: -f1)"
mapfile -t freshness_lines < <(grep -nFx '          verify_current_main' \
  "${DEPLOY_WORKFLOW}" | cut -d: -f1)
stream_line="$(grep -nF 'tar --create --file - -- finguard-release.tgz finguard-release.tgz.sig' \
  "${DEPLOY_WORKFLOW}" | cut -d: -f1)"
activate_line="$(grep -nF '"${SSH_TARGET}" finguard-deploy-activate-stream' \
  "${DEPLOY_WORKFLOW}" | cut -d: -f1)"
test -n "${check_line}" && test -n "${execution_line}" && test "${check_line}" -lt "${execution_line}"
test -n "${write_line}" && test -n "${nginx_reload_line}" && test "${nginx_reload_line}" -lt "${write_line}"
test -n "${host_main_check_line}" && test -n "${activation_started_line}"
test "$((host_main_check_line + 4))" -eq "${activation_started_line}"
test "${#freshness_lines[@]}" -eq 1
test -n "${stream_line}" && test -n "${activate_line}"
test "$((freshness_lines[0] + 1))" -eq "${stream_line}"
test "${stream_line}" -lt "${activate_line}"
grep -Fq 'install -o root -g root -m 0600 /dev/null "${RELEASE_HIGH_WATER_LOCK}"' "${SETUP_RUNNER}"
grep -Fq 'schema=finguard-release-metadata-v1' "${SETUP_RUNNER}"
grep -Fq 'readonly DEPLOY_USER="finguard-deploy"' "${SETUP_RUNNER}"
grep -Fq 'readonly DEPLOY_HOME="/home/finguard-deploy"' "${SETUP_RUNNER}"
grep -Fq 'readonly DEPLOY_STAGING_ROOT="${DEPLOY_HOME}/finguard-deploy"' \
  "${SETUP_RUNNER}"
grep -Fq 'readonly DEPLOY_SUDOERS_FILE="/etc/sudoers.d/finguard-deploy"' \
  "${SETUP_RUNNER}"
grep -Fq 'readonly DEPLOY_SUDOERS_RULE="finguard-deploy ALL=(root) NOPASSWD: /usr/local/sbin/finguard-deploy-release /home/finguard-deploy/finguard-deploy/finguard-release.tgz /home/finguard-deploy/finguard-deploy/finguard-release.tgz.sig"' \
  "${SETUP_RUNNER}"
grep -Fq -- "--groups ''" "${SETUP_RUNNER}"
grep -Fq 'passwd --lock "${DEPLOY_USER}"' "${SETUP_RUNNER}"
grep -Fq 'deploy account password must be locked' "${SETUP_RUNNER}"
grep -Fq '"${DEPLOY_STAGING_ROOT}"' "${SETUP_RUNNER}"
grep -Fq 'chmod 0440 "${deploy_sudoers_temporary}"' "${SETUP_RUNNER}"
[[ "$(grep -Fc 'visudo --check --file' "${SETUP_RUNNER}")" -eq 2 ]]
grep -Fq 'bash deploy/scripts/test-release-metadata.sh' "${CI_WORKFLOW}"
[[ "$(grep -Fc 'readonly OCI_USER=finguard-deploy' "${DEPLOY_WORKFLOW}")" -eq 1 ]]
[[ "$(grep -Fc 'readonly DEPLOY_PATH=' "${DEPLOY_WORKFLOW}")" -eq 0 ]]
if grep -Eq 'secrets\.(OCI_USER|DEPLOY_PATH)' "${DEPLOY_WORKFLOW}"; then
  printf 'test-release-metadata: deploy identity or staging path must not be configurable\n' >&2
  exit 1
fi
grep -Fq 'tar --create --file - -- finguard-release.tgz finguard-release.tgz.sig' \
  "${DEPLOY_WORKFLOW}"
grep -Fq '"${SSH_TARGET}" finguard-deploy-activate-stream' "${DEPLOY_WORKFLOW}"
if grep -Eq '(^|[[:space:]])scp([[:space:]]|$)|sudo --non-interactive /usr/local/sbin/finguard-deploy-release|--allow-rollback' \
  "${DEPLOY_WORKFLOW}"; then
  printf 'test-release-metadata: workflow must stream one forward release command\n' >&2
  exit 1
fi

printf 'release metadata anti-replay contract passed\n'
