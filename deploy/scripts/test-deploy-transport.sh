#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly DISPATCHER="${SCRIPT_DIR}/deploy-transport.sh"
readonly SETUP="${SCRIPT_DIR}/setup-oci.sh"
readonly DEPLOY_WORKFLOW="${SCRIPT_DIR}/../../.github/workflows/deploy.yml"
readonly INSTALLED_DISPATCHER="/usr/local/libexec/finguard-deploy-transport"
readonly ARCHIVE="/home/finguard-deploy/finguard-deploy/finguard-release.tgz"
readonly SIGNATURE="/home/finguard-deploy/finguard-deploy/finguard-release.tgz.sig"
readonly LEGACY_ACTIVATION="sudo --non-interactive /usr/local/sbin/finguard-deploy-release ${ARCHIVE} ${SIGNATURE}"
readonly STREAM_COMMAND="finguard-deploy-activate-stream"

fail() {
  printf 'test-deploy-transport: %s\n' "$*" >&2
  exit 1
}

expect_reject() {
  local label="$1"
  local original_command="$2"
  local output
  output="$(mktemp)"
  if env SSH_ORIGINAL_COMMAND="${original_command}" \
    bash "${DISPATCHER}" -c "${INSTALLED_DISPATCHER}" >"${output}" 2>&1; then
    rm -f -- "${output}"
    fail "${label} unexpectedly succeeded"
  fi
  grep -Fxq 'finguard-deploy-transport: command rejected' "${output}" || {
    rm -f -- "${output}"
    fail "${label} did not fail at the dispatcher boundary"
  }
  rm -f -- "${output}"
}

run_fixture() {
  local input_path="$1"
  local expected_status="$2"
  local output_path="$3"
  local actual_status
  set +e
  env \
    SSH_ORIGINAL_COMMAND="${STREAM_COMMAND}" \
    FAKE_SUDO_LOG="${FAKE_SUDO_LOG}" \
    FAKE_SUDO_STATUS="${FAKE_SUDO_STATUS:-0}" \
    bash "${FIXTURE_DISPATCHER}" -c "${FIXTURE_DISPATCHER}" \
      <"${input_path}" >"${output_path}" 2>&1
  actual_status=$?
  set -e
  [[ "${actual_status}" -eq "${expected_status}" ]] || \
    fail "fixture returned ${actual_status}; expected ${expected_status}: $(tr '\n' ' ' <"${output_path}")"
}

make_regular_stream() {
  local stream_path="$1"
  local archive_content="$2"
  local signature_content="$3"
  local payload_directory
  payload_directory="$(mktemp -d "${TEST_ROOT}/payload.XXXXXXXXXX")"
  printf '%s' "${archive_content}" >"${payload_directory}/finguard-release.tgz"
  printf '%s' "${signature_content}" >"${payload_directory}/finguard-release.tgz.sig"
  tar --create --file "${stream_path}" --directory "${payload_directory}" \
    finguard-release.tgz finguard-release.tgz.sig
  rm -f -- \
    "${payload_directory}/finguard-release.tgz" \
    "${payload_directory}/finguard-release.tgz.sig"
  rmdir -- "${payload_directory}"
}

[[ -f "${DISPATCHER}" && ! -L "${DISPATCHER}" ]] || fail "dispatcher is missing"
[[ "$(head -n 1 "${DISPATCHER}")" == '#!/bin/bash' ]] || \
  fail "dispatcher must use an absolute shell interpreter"

TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

# These commands must be rejected as inert strings before any shell, network,
# loopback, alternate-path, rollback, or legacy transport operation can execute.
expect_reject "empty command" ""
expect_reject "loopback curl" \
  "curl --fail http://127.0.0.1:8000/api/v1/health"
expect_reject "interactive shell" "/bin/bash -i"
expect_reject "shell expression" "sh -c 'id > /tmp/finguard-transport-shell-ran'"
expect_reject "legacy archive upload" "scp -t ${ARCHIVE}"
expect_reject "legacy signature upload" "scp -t ${SIGNATURE}"
expect_reject "bare activation" "${LEGACY_ACTIVATION}"
expect_reject "rollback" "${LEGACY_ACTIVATION} --allow-rollback"
if env SSH_ORIGINAL_COMMAND="${STREAM_COMMAND}" \
  bash "${DISPATCHER}" -c wrong-dispatcher >/dev/null 2>&1; then
  fail "invalid sshd argv unexpectedly succeeded"
fi

# The production dispatcher has one exact command, absolute executables, a
# bounded container, strict two-file validation, and signal-safe cleanup.
grep -Fq 'readonly STREAM_COMMAND="finguard-deploy-activate-stream"' "${DISPATCHER}"
grep -Fq '[[ "${SSH_ORIGINAL_COMMAND-}" == "${STREAM_COMMAND}" ]] || reject' "${DISPATCHER}"
grep -Fq '/usr/bin/head --bytes "$((MAX_INCOMING_CONTAINER_BYTES + 1))"' "${DISPATCHER}"
grep -Fq '"${#incoming_entries[@]}" -eq 2' "${DISPATCHER}"
grep -Fq '"${incoming_entries[0]}" == "finguard-release.tgz"' "${DISPATCHER}"
grep -Fq '"${incoming_entries[1]}" == "finguard-release.tgz.sig"' "${DISPATCHER}"
grep -Fq '"${incoming_verbose_entries[0]:0:1}" == "-"' "${DISPATCHER}"
grep -Fq '"${incoming_verbose_entries[1]:0:1}" == "-"' "${DISPATCHER}"
grep -Fq 'archive_size <= MAX_RELEASE_ARCHIVE_BYTES' "${DISPATCHER}"
grep -Fq 'signature_size <= MAX_RELEASE_SIGNATURE_BYTES' "${DISPATCHER}"
grep -Fq '/usr/bin/flock --exclusive 9' "${DISPATCHER}" || \
  fail "production dispatcher must use absolute flock"
lock_line="$(grep -nF 'exec 9<"${STAGING_ROOT}"' "${DISPATCHER}" | cut -d: -f1)"
flock_line="$(grep -nF '/usr/bin/flock --exclusive 9' "${DISPATCHER}" | cut -d: -f1)"
cleanup_line="$(grep -nF '/usr/bin/rm -f -- "${RELEASE_ARCHIVE}" "${RELEASE_SIGNATURE}"' \
  "${DISPATCHER}" | tail -n 1 | cut -d: -f1)"
head_line="$(grep -nF '/usr/bin/head --bytes' "${DISPATCHER}" | cut -d: -f1)"
mapfile -t move_lines < <(grep -nF '/usr/bin/mv --no-target-directory --' \
  "${DISPATCHER}" | cut -d: -f1)
sudo_line="$(grep -nF '/usr/bin/sudo --non-interactive \' "${DISPATCHER}" | cut -d: -f1)"
[[ -n "${lock_line}" && -n "${flock_line}" && -n "${cleanup_line}" && -n "${head_line}" && \
   "${#move_lines[@]}" -eq 2 && -n "${sudo_line}" && \
   "${lock_line}" -lt "${flock_line}" && "${flock_line}" -lt "${cleanup_line}" && \
   "${cleanup_line}" -lt "${head_line}" && "${head_line}" -lt "${move_lines[0]}" && \
   "${move_lines[0]}" -lt "${move_lines[1]}" && "${move_lines[1]}" -lt "${sudo_line}" ]] || \
  fail "dispatcher ordering must be lock, cleanup, bounded receive, moves, sudo"
grep -Fq "trap 'handle_signal 129' HUP" "${DISPATCHER}"
grep -Fq "trap 'handle_signal 130' INT" "${DISPATCHER}"
grep -Fq "trap 'handle_signal 143' TERM" "${DISPATCHER}"
[[ "$(grep -Fc '/usr/bin/mv --no-target-directory --' "${DISPATCHER}")" -eq 2 ]] || \
  fail "dispatcher must move exactly two validated files to fixed paths"
[[ "$(grep -Fc '/usr/bin/sudo --non-interactive \' "${DISPATCHER}")" -eq 1 ]] || \
  fail "dispatcher must invoke the exact privileged runner once"
grep -Fq 'exit "${activation_status}"' "${DISPATCHER}" || \
  fail "dispatcher must preserve the release runner exit status"
if grep -Eq '(^|[[:space:]])(eval|bash[[:space:]]+-c|sh[[:space:]]+-c)([[:space:]]|$)' "${DISPATCHER}"; then
  fail "dispatcher must not evaluate the original command"
fi
if grep -Eq 'exec[[:space:]]+/usr/bin/(scp|ssh)|/usr/bin/scp' "${DISPATCHER}"; then
  fail "dispatcher must not retain an SCP execution path"
fi

# Exercise the accepted branch without sudo or fixed host paths. This copy
# changes only constants and the sudo binary so the production control flow is
# tested against an isolated fixture with deliberately small size ceilings.
FIXTURE_STAGING="${TEST_ROOT}/staging"
FIXTURE_DISPATCHER="${TEST_ROOT}/finguard-deploy-transport"
FAKE_FLOCK="${TEST_ROOT}/fake-flock"
FAKE_SUDO="${TEST_ROOT}/fake-sudo"
FAKE_SUDO_LOG="${TEST_ROOT}/fake-sudo.log"
readonly FIXTURE_STAGING FIXTURE_DISPATCHER FAKE_FLOCK FAKE_SUDO FAKE_SUDO_LOG
mkdir -- "${FIXTURE_STAGING}"
sed \
  -e "s|readonly TRANSPORT_COMMAND=\"${INSTALLED_DISPATCHER}\"|readonly TRANSPORT_COMMAND=\"${FIXTURE_DISPATCHER}\"|" \
  -e "s|readonly STAGING_ROOT=\"/home/finguard-deploy/finguard-deploy\"|readonly STAGING_ROOT=\"${FIXTURE_STAGING}\"|" \
  -e 's|readonly MAX_RELEASE_ARCHIVE_BYTES="268435456"|readonly MAX_RELEASE_ARCHIVE_BYTES="32"|' \
  -e 's|readonly MAX_RELEASE_SIGNATURE_BYTES="16384"|readonly MAX_RELEASE_SIGNATURE_BYTES="16"|' \
  -e 's|readonly MAX_INCOMING_CONTAINER_BYTES="268500000"|readonly MAX_INCOMING_CONTAINER_BYTES="12288"|' \
  -e "s|/usr/bin/flock|${FAKE_FLOCK}|" \
  -e "s|/usr/bin/sudo|${FAKE_SUDO}|" \
  "${DISPATCHER}" >"${FIXTURE_DISPATCHER}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ $# -eq 2 && "$1" == "--exclusive" && "$2" == "9" ]] || exit 94' \
  'exit 0' >"${FAKE_FLOCK}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  '[[ $# -eq 4 && "$1" == "--non-interactive" ]] || exit 91' \
  '[[ "$2" == "/usr/local/sbin/finguard-deploy-release" ]] || exit 92' \
  '[[ -f "$3" && ! -L "$3" && -f "$4" && ! -L "$4" ]] || exit 93' \
  'printf "%s|%s\n" "$(<"$3")" "$(<"$4")" >"${FAKE_SUDO_LOG}"' \
  'exit "${FAKE_SUDO_STATUS}"' >"${FAKE_SUDO}"
chmod 0700 -- "${FIXTURE_DISPATCHER}" "${FAKE_FLOCK}" "${FAKE_SUDO}"

valid_stream="${TEST_ROOT}/valid.tar"
valid_output="${TEST_ROOT}/valid.out"
make_regular_stream "${valid_stream}" fresh-archive fresh-signature
printf 'stale archive' >"${FIXTURE_STAGING}/finguard-release.tgz"
printf 'stale signature' >"${FIXTURE_STAGING}/finguard-release.tgz.sig"
FAKE_SUDO_STATUS=23 run_fixture "${valid_stream}" 23 "${valid_output}"
[[ "$(<"${FAKE_SUDO_LOG}")" == 'fresh-archive|fresh-signature' ]] || \
  fail "runner did not receive the exact streamed files"
[[ ! -e "${FIXTURE_STAGING}/finguard-release.tgz" && \
   ! -e "${FIXTURE_STAGING}/finguard-release.tgz.sig" ]] || \
  fail "fixed files were not cleaned after runner failure"
[[ -z "$(find "${FIXTURE_STAGING}" -mindepth 1 -print -quit)" ]] || \
  fail "isolated incoming directory was not cleaned"

rm -f -- "${FAKE_SUDO_LOG}"
extra_payload="${TEST_ROOT}/extra-payload"
extra_stream="${TEST_ROOT}/extra.tar"
mkdir -- "${extra_payload}"
printf archive >"${extra_payload}/finguard-release.tgz"
printf signature >"${extra_payload}/finguard-release.tgz.sig"
printf extra >"${extra_payload}/unexpected"
tar --create --file "${extra_stream}" --directory "${extra_payload}" \
  finguard-release.tgz finguard-release.tgz.sig unexpected
printf 'stranded archive' >"${FIXTURE_STAGING}/finguard-release.tgz"
printf 'stranded signature' >"${FIXTURE_STAGING}/finguard-release.tgz.sig"
run_fixture "${extra_stream}" 65 "${TEST_ROOT}/extra.out"
[[ ! -e "${FAKE_SUDO_LOG}" ]] || fail "extra-entry container reached sudo"
[[ ! -e "${FIXTURE_STAGING}/finguard-release.tgz" && \
   ! -e "${FIXTURE_STAGING}/finguard-release.tgz.sig" ]] || \
  fail "invalid stream did not remove stranded fixed files"

python - "${TEST_ROOT}/link.tar" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w") as bundle:
    archive = tarfile.TarInfo("finguard-release.tgz")
    archive.size = 7
    bundle.addfile(archive, io.BytesIO(b"archive"))
    signature = tarfile.TarInfo("finguard-release.tgz.sig")
    signature.type = tarfile.SYMTYPE
    signature.linkname = "finguard-release.tgz"
    bundle.addfile(signature)
PY
run_fixture "${TEST_ROOT}/link.tar" 65 "${TEST_ROOT}/link.out"
[[ ! -e "${FAKE_SUDO_LOG}" ]] || fail "link entry reached sudo"

oversize_stream="${TEST_ROOT}/oversize-file.tar"
make_regular_stream "${oversize_stream}" 123456789012345678901234567890123 signature
run_fixture "${oversize_stream}" 65 "${TEST_ROOT}/oversize-file.out"
[[ ! -e "${FAKE_SUDO_LOG}" ]] || fail "oversize archive reached sudo"

oversize_signature_stream="${TEST_ROOT}/oversize-signature.tar"
make_regular_stream "${oversize_signature_stream}" archive 12345678901234567
run_fixture "${oversize_signature_stream}" 65 "${TEST_ROOT}/oversize-signature.out"
[[ ! -e "${FAKE_SUDO_LOG}" ]] || fail "oversize signature reached sudo"

dd if=/dev/zero of="${TEST_ROOT}/oversize-container.tar" bs=12289 count=1 status=none
run_fixture "${TEST_ROOT}/oversize-container.tar" 65 "${TEST_ROOT}/oversize-container.out"
[[ ! -e "${FAKE_SUDO_LOG}" ]] || fail "oversize container reached sudo"
[[ -z "$(find "${FIXTURE_STAGING}" -mindepth 1 -print -quit)" ]] || \
  fail "failed stream left staged data behind"

# Setup owns both the forced-command executable and the key record so the
# transport user cannot replace either boundary after authentication.
grep -Fq 'readonly DEPLOY_TRANSPORT="/usr/local/libexec/finguard-deploy-transport"' \
  "${SETUP}"
grep -Fq 'readonly DEPLOY_AUTHORIZED_KEYS="${DEPLOY_HOME}/.ssh/authorized_keys"' \
  "${SETUP}"
grep -Fq 'restrict,command="/usr/local/libexec/finguard-deploy-transport" ssh-ed25519' \
  "${SETUP}"
grep -Fq 'install -d -o root -g "${DEPLOY_GROUP}" -m 0750 "${DEPLOY_HOME}"' \
  "${SETUP}"
grep -Fq 'install -d -o root -g root -m 0755 "${DEPLOY_HOME}/.ssh"' "${SETUP}"
grep -Fq 'deploy authorized_keys must be root-owned, deploy-group-readable, and mode 0640' \
  "${SETUP}"
grep -Fq 'malformed, multiple, or unrestricted deploy authorized_keys records were disabled' \
  "${SETUP}"
grep -Fq 'passwd --lock "${DEPLOY_USER}"' "${SETUP}"
grep -Fq 'transport shell' "${SETUP}"

# Exercise the exact setup regex with an ephemeral public key. No generated key
# material is retained in the repository or after this contract exits.
source <(grep -F 'readonly DEPLOY_AUTHORIZED_KEY_REGEX=' "${SETUP}")
ssh-keygen -q -t ed25519 -N '' -C finguard-transport \
  -f "${TEST_ROOT}/transport"
generated_public="$(ssh-keygen -y -f "${TEST_ROOT}/transport")"
read -r generated_type generated_blob generated_comment generated_extra <<<"${generated_public}"
[[ "${generated_type}" == "ssh-ed25519" && \
   "${generated_blob}" =~ ^[A-Za-z0-9+/]+={0,2}$ && \
   ( -z "${generated_comment}" || "${generated_comment}" == "finguard-transport" ) && \
   -z "${generated_extra}" ]] || fail "ssh-keygen returned an unexpected public key record"
valid_record="restrict,command=\"${INSTALLED_DISPATCHER}\" ${generated_type} ${generated_blob} finguard-transport"
[[ "${valid_record}" =~ ${DEPLOY_AUTHORIZED_KEY_REGEX} ]] || \
  fail "exact restricted Ed25519 record was rejected"
printf '%s\n' "${valid_record}" >"${TEST_ROOT}/authorized_keys"
ssh-keygen -l -f "${TEST_ROOT}/authorized_keys" >/dev/null || \
  fail "exact restricted Ed25519 record was not accepted by ssh-keygen"
[[ ! "${generated_public} finguard-transport" =~ ${DEPLOY_AUTHORIZED_KEY_REGEX} ]] || \
  fail "unrestricted Ed25519 record was accepted"
[[ ! "${valid_record} extra" =~ ${DEPLOY_AUTHORIZED_KEY_REGEX} ]] || \
  fail "malformed restricted record was accepted"
grep -Fq '"${#deploy_authorized_key_lines[@]}" -ne 1' "${SETUP}" || \
  fail "setup must reject multiple authorized key records"

# The client must create exactly one two-entry uncompressed stream and one SSH
# request for the exact command accepted above.
[[ "$(grep -Fxc '          verify_current_main' "${DEPLOY_WORKFLOW}")" -eq 1 ]] || \
  fail "workflow must make one fresh authorized-main check"
grep -Fq 'tar --create --file - -- finguard-release.tgz finguard-release.tgz.sig' \
  "${DEPLOY_WORKFLOW}"
grep -Fq '"${SSH_TARGET}" finguard-deploy-activate-stream' "${DEPLOY_WORKFLOW}"
[[ "$(grep -Ec '^[[:space:]]+(scp|ssh)[[:space:]]' "${DEPLOY_WORKFLOW}")" -eq 1 ]] || \
  fail "workflow must make exactly one deployment transport call"
if grep -Eq '(^|[[:space:]])scp([[:space:]]|$)|sudo --non-interactive /usr/local/sbin/finguard-deploy-release' \
  "${DEPLOY_WORKFLOW}"; then
  fail "workflow must not retain SCP or bare activation"
fi

printf 'streamed deployment SSH transport contract passed\n'
