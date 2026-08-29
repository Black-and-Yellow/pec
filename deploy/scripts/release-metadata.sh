#!/usr/bin/env bash
set -Eeuo pipefail

readonly RELEASE_METADATA_SCHEMA="finguard-release-metadata-v1"

fail() {
  printf 'release-metadata: %s\n' "$*" >&2
  exit 1
}

validate_owner_mode() {
  local path="$1"
  local expected_owner="$2"
  local system_name test_root resolved_root resolved_path

  [[ -f "${path}" && ! -L "${path}" ]] || \
    fail "release high-water state must be a regular, non-symlink file"

  # NTFS through MSYS cannot represent the POSIX 0600 fixture used by the
  # contract test. This bypass is deliberately unavailable to the root-run
  # Linux deployment and is confined to a marked Git Bash temporary directory.
  if [[ -n "${FINGUARD_RELEASE_METADATA_TEST_ROOT:-}" ]]; then
    [[ "${FINGUARD_RELEASE_METADATA_TEST_BYPASS_FILE_SECURITY:-}" == "1" ]] || \
      fail "test file-security bypass requires its explicit guard"
    [[ ${EUID} -ne 0 ]] || fail "test file-security bypass is forbidden for root"
    system_name="$(uname -s)"
    case "${system_name}" in
      MINGW*|MSYS*|CYGWIN*) ;;
      *) fail "test file-security bypass is supported only by Git Bash on Windows" ;;
    esac
    test_root="${FINGUARD_RELEASE_METADATA_TEST_ROOT}"
    [[ "${test_root}" == /* && -d "${test_root}" && ! -L "${test_root}" ]] || \
      fail "test file-security root must be an absolute, regular directory"
    [[ -f "${test_root}/.finguard-release-metadata-test-root" && \
       ! -L "${test_root}/.finguard-release-metadata-test-root" ]] || \
      fail "test file-security root marker is missing"
    grep -Fxq 'finguard-release-metadata-test-only' \
      "${test_root}/.finguard-release-metadata-test-root" || \
      fail "test file-security root marker is invalid"
    resolved_root="$(cd -- "${test_root}" && pwd -P)"
    resolved_path="$(cd -- "$(dirname -- "${path}")" && pwd -P)/$(basename -- "${path}")"
    [[ "${resolved_path}" == "${resolved_root}/"* ]] || \
      fail "test file-security bypass path escapes its test root"
    return
  fi
  [[ -z "${FINGUARD_RELEASE_METADATA_TEST_BYPASS_FILE_SECURITY:-}" ]] || \
    fail "test file-security bypass guard requires a test root"
  [[ "$(stat --format='%u:%g:%a' -- "${path}")" == "${expected_owner}:600" ]] || \
    fail "release high-water state must have the required owner and mode 0600"
}

read_record() {
  local path="$1"
  local allow_zero="$2"
  local label="$3"
  local -n sequence_result="$4"
  local -n commit_result="$5"
  local -a lines=()

  [[ -f "${path}" && ! -L "${path}" ]] || \
    fail "${label} must be a regular, non-symlink file"
  mapfile -t lines <"${path}"
  [[ ${#lines[@]} -eq 3 ]] || fail "${label} must contain exactly three lines"
  [[ "${lines[0]}" == "schema=${RELEASE_METADATA_SCHEMA}" ]] || \
    fail "${label} schema is invalid"
  [[ "${lines[1]}" =~ ^sequence=([0-9]+)$ ]] || fail "${label} sequence is invalid"
  sequence_result="${BASH_REMATCH[1]}"
  [[ "${sequence_result}" == "0" || "${sequence_result}" != 0* ]] || \
    fail "${label} sequence must use canonical decimal form"
  if [[ "${allow_zero}" != true && "${sequence_result}" == "0" ]]; then
    fail "${label} sequence must be greater than zero"
  fi
  [[ "${lines[2]}" =~ ^commit=([0-9a-f]{40})$ ]] || \
    fail "${label} commit must be exactly 40 lowercase hexadecimal characters"
  commit_result="${BASH_REMATCH[1]}"
}

compare_decimal() {
  local left="$1"
  local right="$2"

  if (( ${#left} < ${#right} )); then
    printf '%s\n' -1
  elif (( ${#left} > ${#right} )); then
    printf '%s\n' 1
  elif [[ "${left}" == "${right}" ]]; then
    printf '%s\n' 0
  elif [[ "${left}" < "${right}" ]]; then
    printf '%s\n' -1
  else
    printf '%s\n' 1
  fi
}

check_release() {
  local metadata_path="$1"
  local state_path="$2"
  local mode="$3"
  local expected_owner="$4"
  local release_sequence release_commit state_sequence state_commit comparison

  [[ "${mode}" == "forward" || "${mode}" == "rollback" ]] || \
    fail "comparison mode must be forward or rollback"
  [[ "${expected_owner}" =~ ^[0-9]+:[0-9]+$ ]] || fail "expected owner is invalid"
  validate_owner_mode "${state_path}" "${expected_owner}"
  read_record "${metadata_path}" false "signed release metadata" \
    release_sequence release_commit
  read_record "${state_path}" true "release high-water state" \
    state_sequence state_commit

  comparison="$(compare_decimal "${release_sequence}" "${state_sequence}")"
  [[ "${comparison}" != 0 ]] || fail "release sequence replays the highest accepted release"
  if [[ "${mode}" == "forward" ]]; then
    [[ "${comparison}" == 1 ]] || fail "release sequence is below the highest accepted release"
  else
    [[ "${comparison}" == -1 ]] || \
      fail "rollback override requires a release below the highest accepted release"
  fi

  printf '%s %s\n' "${release_sequence}" "${release_commit}"
}

write_state() {
  local state_path="$1"
  local sequence="$2"
  local commit="$3"
  local expected_owner="$4"
  local state_directory state_temporary current_sequence current_commit comparison

  [[ "${expected_owner}" =~ ^[0-9]+:[0-9]+$ ]] || fail "expected owner is invalid"
  validate_owner_mode "${state_path}" "${expected_owner}"
  read_record "${state_path}" true "release high-water state" \
    current_sequence current_commit
  [[ "${sequence}" =~ ^[1-9][0-9]*$ ]] || fail "new release sequence is invalid"
  [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || fail "new release commit is invalid"

  comparison="$(compare_decimal "${sequence}" "${current_sequence}")"
  if [[ "${comparison}" == -1 ]]; then
    return
  fi
  if [[ "${comparison}" == 0 ]]; then
    [[ "${commit}" == "${current_commit}" ]] || \
      fail "new release sequence conflicts with the recorded commit"
    return
  fi

  state_directory="$(dirname -- "${state_path}")"
  [[ -d "${state_directory}" && ! -L "${state_directory}" ]] || \
    fail "release high-water state directory must be a regular directory"
  state_temporary="$(mktemp "${state_directory}/.release-high-water.XXXXXX")"
  trap 'rm -f -- "${state_temporary}"' RETURN
  chmod 0600 "${state_temporary}"
  chown "${expected_owner}" "${state_temporary}"
  printf 'schema=%s\nsequence=%s\ncommit=%s\n' \
    "${RELEASE_METADATA_SCHEMA}" "${sequence}" "${commit}" >"${state_temporary}"
  validate_owner_mode "${state_temporary}" "${expected_owner}"
  mv -- "${state_temporary}" "${state_path}"
  trap - RETURN
}

check_authorized_main() {
  local tested_commit="$1"
  local authorized_main_ref="$2"
  local authorized_commit

  [[ "${tested_commit}" =~ ^[0-9a-f]{40}$ ]] || \
    fail "tested commit must be exactly 40 lowercase hexadecimal characters"
  [[ "${authorized_main_ref}" != *$'\n'* && \
     "${authorized_main_ref}" == *$'\trefs/heads/main' ]] || \
    fail "authorized main ref must be one strict ls-remote record"
  authorized_commit="${authorized_main_ref%%$'\t'*}"
  [[ "${authorized_main_ref}" == "${authorized_commit}"$'\trefs/heads/main' && \
     "${authorized_commit}" =~ ^[0-9a-f]{40}$ ]] || \
    fail "authorized main ref must contain one valid main commit"
  [[ "${tested_commit}" == "${authorized_commit}" ]] || \
    fail "tested commit is no longer the authorized main revision"

  printf '%s\n' "${authorized_commit}"
}

case "${1:-}" in
  check-authorized-main)
    [[ $# -eq 3 ]] || \
      fail "usage: $0 check-authorized-main TESTED_COMMIT LS_REMOTE_MAIN_RECORD"
    check_authorized_main "$2" "$3"
    ;;
  check)
    [[ $# -eq 5 ]] || fail "usage: $0 check METADATA STATE forward|rollback UID:GID"
    check_release "$2" "$3" "$4" "$5"
    ;;
  write-state)
    [[ $# -eq 5 ]] || fail "usage: $0 write-state STATE SEQUENCE COMMIT UID:GID"
    write_state "$2" "$3" "$4" "$5"
    ;;
  *)
    fail "usage: $0 check-authorized-main ... | check ... | write-state ..."
    ;;
esac
