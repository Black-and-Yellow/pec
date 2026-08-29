#!/bin/bash
set -Eeuo pipefail

readonly TRANSPORT_COMMAND="/usr/local/libexec/finguard-deploy-transport"
readonly STREAM_COMMAND="finguard-deploy-activate-stream"
readonly STAGING_ROOT="/home/finguard-deploy/finguard-deploy"
readonly RELEASE_ARCHIVE="${STAGING_ROOT}/finguard-release.tgz"
readonly RELEASE_SIGNATURE="${STAGING_ROOT}/finguard-release.tgz.sig"
readonly MAX_RELEASE_ARCHIVE_BYTES="268435456"
readonly MAX_RELEASE_SIGNATURE_BYTES="16384"
readonly MAX_INCOMING_CONTAINER_BYTES="268500000"

incoming_directory=""
incoming_container=""
incoming_listing=""
incoming_verbose_listing=""
incoming_payload=""

reject() {
  printf 'finguard-deploy-transport: command rejected\n' >&2
  exit 64
}

fail() {
  printf 'finguard-deploy-transport: %s\n' "$1" >&2
  exit 65
}

cleanup() {
  set +e
  /usr/bin/rm -f -- "${RELEASE_ARCHIVE}" "${RELEASE_SIGNATURE}"
  if [[ -n "${incoming_payload}" ]]; then
    /usr/bin/rm -f -- \
      "${incoming_payload}/finguard-release.tgz" \
      "${incoming_payload}/finguard-release.tgz.sig"
    /usr/bin/rmdir -- "${incoming_payload}" 2>/dev/null
  fi
  if [[ -n "${incoming_directory}" ]]; then
    /usr/bin/rm -f -- \
      "${incoming_container}" \
      "${incoming_listing}" \
      "${incoming_verbose_listing}"
    /usr/bin/rmdir -- "${incoming_directory}" 2>/dev/null
  fi
  return 0
}

handle_signal() {
  readonly signal_status="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "${signal_status}"
}

# sshd invokes the account's configured shell as `shell -c forced-command`.
# Requiring that exact shape also prevents this file from becoming a general
# local command runner if the transport account is invoked another way.
[[ $# -eq 2 && "$1" == "-c" && "$2" == "${TRANSPORT_COMMAND}" ]] || reject
[[ "${SSH_ORIGINAL_COMMAND-}" == "${STREAM_COMMAND}" ]] || reject

umask 0077
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# Serialize on the fixed staging directory inode before cleanup or receive so
# concurrent uses of the same key cannot replace files while sudo reads them.
exec 9<"${STAGING_ROOT}"
/usr/bin/flock --exclusive 9

# Remove leftovers from an interrupted prior stream before accepting any new
# bytes. The fixed paths remain absent until the complete container is valid.
/usr/bin/rm -f -- "${RELEASE_ARCHIVE}" "${RELEASE_SIGNATURE}"
[[ ! -e "${RELEASE_ARCHIVE}" && ! -L "${RELEASE_ARCHIVE}" && \
   ! -e "${RELEASE_SIGNATURE}" && ! -L "${RELEASE_SIGNATURE}" ]] || \
  fail "fixed staging paths could not be cleaned"

incoming_directory="$(/usr/bin/mktemp --directory "${STAGING_ROOT}/.finguard-stream.XXXXXXXXXX")"
incoming_container="${incoming_directory}/incoming.tar"
incoming_listing="${incoming_directory}/entries.list"
incoming_verbose_listing="${incoming_directory}/entries.verbose"
incoming_payload="${incoming_directory}/payload"
/usr/bin/mkdir -- "${incoming_payload}"

# Read at most one byte beyond the container limit. A larger producer receives
# a closed stream and cannot consume unbounded staging disk.
/usr/bin/head --bytes "$((MAX_INCOMING_CONTAINER_BYTES + 1))" >"${incoming_container}"
incoming_size="$(/usr/bin/stat --format='%s' -- "${incoming_container}")"
[[ "${incoming_size}" =~ ^[0-9]+$ ]] || fail "incoming container size is invalid"
(( incoming_size > 0 && incoming_size <= MAX_INCOMING_CONTAINER_BYTES )) || \
  fail "incoming container size is invalid"

/usr/bin/tar --list --file "${incoming_container}" >"${incoming_listing}"
mapfile -t incoming_entries <"${incoming_listing}"
[[ "${#incoming_entries[@]}" -eq 2 && \
   "${incoming_entries[0]}" == "finguard-release.tgz" && \
   "${incoming_entries[1]}" == "finguard-release.tgz.sig" ]] || \
  fail "incoming container must contain exactly the release archive and signature"

/usr/bin/tar --list --verbose --file "${incoming_container}" >"${incoming_verbose_listing}"
mapfile -t incoming_verbose_entries <"${incoming_verbose_listing}"
[[ "${#incoming_verbose_entries[@]}" -eq 2 && \
   "${incoming_verbose_entries[0]:0:1}" == "-" && \
   "${incoming_verbose_entries[1]:0:1}" == "-" ]] || \
  fail "incoming container entries must be regular files"

/usr/bin/tar \
  --extract \
  --file "${incoming_container}" \
  --directory "${incoming_payload}" \
  --no-same-owner \
  --no-same-permissions \
  -- \
  finguard-release.tgz \
  finguard-release.tgz.sig

isolated_archive="${incoming_payload}/finguard-release.tgz"
isolated_signature="${incoming_payload}/finguard-release.tgz.sig"
[[ -f "${isolated_archive}" && ! -L "${isolated_archive}" && \
   -f "${isolated_signature}" && ! -L "${isolated_signature}" ]] || \
  fail "incoming release files must be regular, non-link files"

archive_size="$(/usr/bin/stat --format='%s' -- "${isolated_archive}")"
signature_size="$(/usr/bin/stat --format='%s' -- "${isolated_signature}")"
[[ "${archive_size}" =~ ^[0-9]+$ && "${signature_size}" =~ ^[0-9]+$ ]] || \
  fail "incoming release file size is invalid"
(( archive_size > 0 && archive_size <= MAX_RELEASE_ARCHIVE_BYTES )) || \
  fail "release archive size is invalid"
(( signature_size > 0 && signature_size <= MAX_RELEASE_SIGNATURE_BYTES )) || \
  fail "release signature size is invalid"
/usr/bin/chmod 0600 -- "${isolated_archive}" "${isolated_signature}"

# Do not place either file at its privileged fixed argument until the complete
# stream has passed transport validation. The root runner authenticates the
# exact archive bytes before listing, extracting, or executing their contents.
/usr/bin/mv --no-target-directory -- "${isolated_archive}" "${RELEASE_ARCHIVE}"
/usr/bin/mv --no-target-directory -- "${isolated_signature}" "${RELEASE_SIGNATURE}"
set +e
/usr/bin/sudo --non-interactive \
  /usr/local/sbin/finguard-deploy-release \
  "${RELEASE_ARCHIVE}" \
  "${RELEASE_SIGNATURE}"
activation_status=$?
set -e

cleanup
trap - EXIT HUP INT TERM
exit "${activation_status}"
