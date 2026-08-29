#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HELPER="${SCRIPT_DIR}/https-config.sh"
TEMPLATE="${DEPLOY_DIR}/nginx/finguard-https.conf.template"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

# shellcheck source=deploy/scripts/https-config.sh
source "${HELPER}"

ACTIVE_CONFIG="${TEST_ROOT}/finguard"
CANDIDATE="${TEST_ROOT}/candidate"
DOMAIN="finguard.example.dev"

# This represents an already-enabled site from before the dedicated AI and
# global-auth budgets were added to the trusted template.
cat >"${ACTIVE_CONFIG}" <<EOF
limit_req_zone \$binary_remote_addr zone=finguard_api_per_ip:1m rate=30r/m;
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    location / { return 308 https://${DOMAIN}\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    location ^~ /api/ { proxy_pass http://127.0.0.1:8000; }
}
EOF

! grep -Fq 'finguard_ai_per_ip' "${ACTIVE_CONFIG}"
! grep -Fq 'finguard_auth_global' "${ACTIVE_CONFIG}"
recovered_domain="$(finguard_recover_https_domain "${ACTIVE_CONFIG}")"
[[ "${recovered_domain}" == "${DOMAIN}" ]]
finguard_render_https_candidate "${TEMPLATE}" "${recovered_domain}" "${CANDIDATE}"
grep -Fq 'limit_req_zone $finguard_ai_limit_key zone=finguard_ai_per_ip:1m rate=2r/m;' \
  "${CANDIDATE}"
grep -Fq 'limit_req zone=finguard_ai_per_ip burst=1 nodelay;' "${CANDIDATE}"
grep -Fq 'limit_req_zone $finguard_auth_global_limit_key zone=finguard_auth_global:1m rate=30r/m;' \
  "${CANDIDATE}"
grep -Fq 'limit_req zone=finguard_auth_global burst=10 nodelay;' "${CANDIDATE}"
grep -Fq "return 308 https://${DOMAIN}\$request_uri;" "${CANDIDATE}"
! grep -Fq '__FINGUARD_DOMAIN__' "${CANDIDATE}"

ln -s "${ACTIVE_CONFIG}" "${TEST_ROOT}/linked-config"
if [[ -L "${TEST_ROOT}/linked-config" ]]; then
  if finguard_recover_https_domain "${TEST_ROOT}/linked-config" >/dev/null 2>&1; then
    printf 'symlinked HTTPS config unexpectedly passed recovery\n' >&2
    exit 1
  fi
else
  printf 'HTTPS symlink fixture skipped: this Git Bash host did not create a detectable link\n'
fi

awk -v domain="${DOMAIN}" '
  $1 == "server_name" {
    server_name_count += 1
    if (server_name_count == 2) {
      sub("server_name " domain ";", "server_name other.example.dev;")
    }
  }
  { print }
' "${ACTIVE_CONFIG}" >"${TEST_ROOT}/multiple-domains"
if finguard_recover_https_domain "${TEST_ROOT}/multiple-domains" >/dev/null 2>&1; then
  printf 'multiple HTTPS domains unexpectedly passed recovery\n' >&2
  exit 1
fi

sed 's#/etc/letsencrypt/live/finguard.example.dev/privkey.pem#/tmp/untrusted.key#' \
  "${ACTIVE_CONFIG}" >"${TEST_ROOT}/malformed-certificate"
if finguard_recover_https_domain "${TEST_ROOT}/malformed-certificate" >/dev/null 2>&1; then
  printf 'mismatched certificate path unexpectedly passed recovery\n' >&2
  exit 1
fi

if finguard_validate_https_domain 'Finguard.example.dev' >/dev/null 2>&1; then
  printf 'invalid mixed-case domain unexpectedly passed validation\n' >&2
  exit 1
fi

sed "s/__FINGUARD_DOMAIN__/${DOMAIN}/g" "${TEMPLATE}" >"${TEST_ROOT}/no-placeholder.template"
if finguard_render_https_candidate \
  "${TEST_ROOT}/no-placeholder.template" \
  "${DOMAIN}" \
  "${TEST_ROOT}/no-placeholder.candidate" >/dev/null 2>&1; then
  printf 'template without a domain placeholder unexpectedly rendered\n' >&2
  exit 1
fi

# Exercise activation without root, certificates, Nginx, or systemd. The
# indirection mirrors only file metadata setup and service calls; replacement
# itself remains a same-directory rename in the success fixture.
SUCCESS_ACTIVE="${TEST_ROOT}/success-active"
SUCCESS_EVENTS="${TEST_ROOT}/success-events"
cp -- "${ACTIVE_CONFIG}" "${SUCCESS_ACTIVE}"
(
  finguard_validate_certificate_files() { return 0; }
  finguard_set_https_file_metadata() {
    chmod 0644 "$1" || return 1
    printf 'metadata\n' >>"${SUCCESS_EVENTS}"
  }
  finguard_replace_https_file() {
    printf 'replace\n' >>"${SUCCESS_EVENTS}"
    mv -fT -- "$1" "$2"
  }
  nginx() {
    [[ "$1" == "-t" ]] || return 1
    printf 'validate\n' >>"${SUCCESS_EVENTS}"
  }
  systemctl() {
    [[ "$1" == "reload" && "$2" == "nginx" ]] || return 1
    printf 'reload\n' >>"${SUCCESS_EVENTS}"
  }
  finguard_activate_https_config "${TEMPLATE}" "${SUCCESS_ACTIVE}" "${DOMAIN}"
)
grep -Fq 'finguard_ai_per_ip' "${SUCCESS_ACTIVE}"
test "$(tr '\n' ' ' <"${SUCCESS_EVENTS}")" = 'metadata replace validate reload '

# A failed atomic replacement must not alter even one byte of the active file,
# and validation/reload must not run because no candidate became active.
FAILED_ACTIVE="${TEST_ROOT}/failed-active"
FAILED_EXPECTED="${TEST_ROOT}/failed-expected"
FAILED_EVENTS="${TEST_ROOT}/failed-events"
cp -- "${ACTIVE_CONFIG}" "${FAILED_ACTIVE}"
cp -- "${ACTIVE_CONFIG}" "${FAILED_EXPECTED}"
if (
  finguard_validate_certificate_files() { return 0; }
  finguard_set_https_file_metadata() { chmod 0644 "$1"; }
  finguard_replace_https_file() {
    printf 'replace-failed\n' >>"${FAILED_EVENTS}"
    return 73
  }
  nginx() { printf 'unexpected-nginx\n' >>"${FAILED_EVENTS}"; return 0; }
  systemctl() { printf 'unexpected-systemctl\n' >>"${FAILED_EVENTS}"; return 0; }
  finguard_activate_https_config "${TEMPLATE}" "${FAILED_ACTIVE}" "${DOMAIN}"
) >/dev/null 2>&1; then
  printf 'failed HTTPS replacement unexpectedly succeeded\n' >&2
  exit 1
fi
cmp --silent "${FAILED_EXPECTED}" "${FAILED_ACTIVE}"
test "$(tr '\n' ' ' <"${FAILED_EVENTS}")" = 'replace-failed '

# Once the candidate is active, a validation failure must attempt rollback. If
# that rollback replacement fails, the byte-exact backup must survive cleanup.
ROLLBACK_ACTIVE="${TEST_ROOT}/rollback-active"
ROLLBACK_EXPECTED="${TEST_ROOT}/rollback-expected"
ROLLBACK_ERROR="${TEST_ROOT}/rollback-error"
cp -- "${ACTIVE_CONFIG}" "${ROLLBACK_ACTIVE}"
cp -- "${ACTIVE_CONFIG}" "${ROLLBACK_EXPECTED}"
if (
  replace_count=0
  finguard_validate_certificate_files() { return 0; }
  finguard_set_https_file_metadata() { chmod 0644 "$1"; }
  finguard_replace_https_file() {
    replace_count=$((replace_count + 1))
    if [[ ${replace_count} -eq 1 ]]; then
      mv -fT -- "$1" "$2"
      return $?
    fi
    return 74
  }
  nginx() { return 1; }
  systemctl() { return 0; }
  finguard_activate_https_config "${TEMPLATE}" "${ROLLBACK_ACTIVE}" "${DOMAIN}"
) 2>"${ROLLBACK_ERROR}"; then
  printf 'failed HTTPS rollback unexpectedly succeeded\n' >&2
  exit 1
fi
preserved_backup="$(sed -n 's/.*backup preserved at //p' "${ROLLBACK_ERROR}" | tail -n 1)"
test -n "${preserved_backup}"
test -f "${preserved_backup}"
cmp --silent "${ROLLBACK_EXPECTED}" "${preserved_backup}"

activation_block="$(sed -n '/^finguard_activate_https_config()/,/^)/p' "${HELPER}")"
render_line="$(grep -nF 'finguard_render_https_candidate "${template}" "${domain}" "${candidate}"' \
  <<<"${activation_block}" | cut -d: -f1)"
metadata_line="$(grep -nF 'finguard_set_https_file_metadata "${candidate}"' \
  <<<"${activation_block}" | cut -d: -f1)"
backup_line="$(grep -nF 'cp --preserve=mode,ownership,timestamps' <<<"${activation_block}" | cut -d: -f1)"
replace_line="$(grep -nF 'finguard_replace_https_file "${candidate}" "${active_config}"' \
  <<<"${activation_block}" | cut -d: -f1)"
validate_line="$(grep -nF 'if ! nginx -t; then' <<<"${activation_block}" | cut -d: -f1)"
reload_line="$(grep -nF 'if ! systemctl reload nginx; then' <<<"${activation_block}" | cut -d: -f1)"
test -n "${render_line}" && test -n "${metadata_line}" && test -n "${backup_line}" && \
  test -n "${replace_line}" && test -n "${validate_line}" && test -n "${reload_line}"
test "${render_line}" -lt "${metadata_line}"
test "${metadata_line}" -lt "${backup_line}"
test "${backup_line}" -lt "${replace_line}"
test "${replace_line}" -lt "${validate_line}"
test "${validate_line}" -lt "${reload_line}"

metadata_block="$(sed -n '/^finguard_set_https_file_metadata()/,/^}/p' "${HELPER}")"
grep -Fq 'chown root:root "${config_path}"' <<<"${metadata_block}"
grep -Fq 'chmod 0644 "${config_path}"' <<<"${metadata_block}"

replace_block="$(sed -n '/^finguard_replace_https_file()/,/^}/p' "${HELPER}")"
grep -Fq 'mv -fT -- "${candidate}" "${active_config}"' <<<"${replace_block}"

rollback_block="$(sed -n '/^finguard_restore_https_config()/,/^)/p' "${HELPER}")"
restore_line="$(grep -nF 'finguard_replace_https_file "${rollback_candidate}" "${active_config}"' \
  <<<"${rollback_block}" | cut -d: -f1)"
rollback_test_line="$(grep -nF 'nginx -t' <<<"${rollback_block}" | cut -d: -f1)"
rollback_reload_line="$(grep -nF 'systemctl reload nginx' <<<"${rollback_block}" | cut -d: -f1)"
test -n "${restore_line}" && test -n "${rollback_test_line}" && test -n "${rollback_reload_line}"
test "${restore_line}" -lt "${rollback_test_line}"
test "${rollback_test_line}" -lt "${rollback_reload_line}"

grep -Fq '"${DEPLOY_DIR}/scripts/https-config.sh" --refresh-existing' \
  "${SCRIPT_DIR}/setup-oci.sh"
grep -Fq '"${DEPLOY_DIR}/scripts/https-config.sh" --domain "${DOMAIN}"' \
  "${SCRIPT_DIR}/enable-https.sh"
! grep -Eq 'certbot|curl|wget' "${HELPER}"

printf 'HTTPS template refresh contract passed\n'
