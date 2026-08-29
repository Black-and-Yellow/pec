#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly DEPLOY_WORKFLOW="${REPOSITORY_ROOT}/.github/workflows/deploy.yml"
readonly DEPLOY_RUNNER="${REPOSITORY_ROOT}/deploy/scripts/deploy-release.sh"
readonly SETUP_RUNNER="${REPOSITORY_ROOT}/deploy/scripts/setup-oci.sh"
readonly TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

expect_reject() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'test-release-architecture: expected rejection: %s\n' "${label}" >&2
    exit 1
  fi
}

extract_architecture_gate() {
  local source_path="$1"
  local output_path="$2"
  printf 'fail() { exit 1; }\n' >"${output_path}"
  sed -n '/^require_amd64_host() {$/,/^}$/p' \
    "${source_path}" >>"${output_path}"
  [[ "$(grep -Fc 'require_amd64_host() {' "${output_path}")" -eq 1 ]]
}

run_architecture_gate() {
  local gate_path="$1"
  local dpkg_architecture="$2"
  local machine_architecture="$3"

  TEST_DPKG_ARCHITECTURE="${dpkg_architecture}" \
    TEST_MACHINE_ARCHITECTURE="${machine_architecture}" \
    bash -c '
      dpkg() {
        [[ "$1" == "--print-architecture" ]] || return 1
        printf "%s\n" "${TEST_DPKG_ARCHITECTURE}"
      }
      uname() {
        [[ "$1" == "-m" ]] || return 1
        printf "%s\n" "${TEST_MACHINE_ARCHITECTURE}"
      }
      source "$1"
      require_amd64_host
    ' _ "${gate_path}"
}

setup_gate="${TEST_ROOT}/setup-gate.sh"
deploy_gate="${TEST_ROOT}/deploy-gate.sh"
extract_architecture_gate "${SETUP_RUNNER}" "${setup_gate}"
extract_architecture_gate "${DEPLOY_RUNNER}" "${deploy_gate}"
cmp --silent "${setup_gate}" "${deploy_gate}"

run_architecture_gate "${setup_gate}" amd64 x86_64
run_architecture_gate "${deploy_gate}" amd64 x86_64
for gate_path in "${setup_gate}" "${deploy_gate}"; do
  expect_reject "arm64 Debian architecture" \
    run_architecture_gate "${gate_path}" arm64 aarch64
  expect_reject "mismatched kernel architecture" \
    run_architecture_gate "${gate_path}" amd64 aarch64
  expect_reject "mismatched Debian architecture" \
    run_architecture_gate "${gate_path}" arm64 x86_64
  expect_reject "empty architecture" \
    run_architecture_gate "${gate_path}" '' ''
done

setup_gate_line="$(grep -nFx 'require_amd64_host' "${SETUP_RUNNER}" | cut -d: -f1)"
setup_network_line="$(grep -nFx 'apt-get update' "${SETUP_RUNNER}" | cut -d: -f1)"
deploy_gate_line="$(grep -nFx 'require_amd64_host' "${DEPLOY_RUNNER}" | cut -d: -f1)"
deploy_archive_line="$(grep -nF '[[ -f "${ARCHIVE}" && ! -L "${ARCHIVE}" ]]' \
  "${DEPLOY_RUNNER}" | cut -d: -f1)"
test -n "${setup_gate_line}" && test -n "${setup_network_line}"
test "${setup_gate_line}" -lt "${setup_network_line}"
test -n "${deploy_gate_line}" && test -n "${deploy_archive_line}"
test "${deploy_gate_line}" -lt "${deploy_archive_line}"

grep -Fq 'Build and prove complete amd64 Python wheelhouse' "${DEPLOY_WORKFLOW}"
grep -Fq 'manylinux_2_${glibc_minor}_x86_64' "${DEPLOY_WORKFLOW}"
grep -Fq 'manylinux2014_x86_64' "${DEPLOY_WORKFLOW}"
grep -Fq -- '--only-binary=:all:' "${DEPLOY_WORKFLOW}"
grep -Fq -- '--no-index' "${DEPLOY_WORKFLOW}"
grep -Fq 'sha256sum --check --strict SHA256SUMS' "${DEPLOY_WORKFLOW}"
if grep -Eiq 'ARM64|aarch64|manylinux.*_arm64' "${DEPLOY_WORKFLOW}"; then
  printf 'test-release-architecture: deploy workflow retains an ARM64 target\n' >&2
  exit 1
fi

printf 'amd64 release architecture contract passed\n'
