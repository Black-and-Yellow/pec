#!/usr/bin/env bash
set -Eeuo pipefail

finguard_https_error() {
  printf 'https-config: %s\n' "$*" >&2
  return 1
}

finguard_validate_https_domain() {
  if [[ $# -ne 1 ]]; then
    finguard_https_error "domain validation requires exactly one argument"
    return 1
  fi
  local domain="$1"

  if [[ ! "${domain}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
    finguard_https_error "domain must be a lowercase DNS hostname"
    return 1
  fi
}

finguard_recover_https_domain() {
  if [[ $# -ne 1 ]]; then
    finguard_https_error "domain recovery requires exactly one config path"
    return 1
  fi
  local active_config="$1"
  local recovered_domain=""
  local line=""
  local value=""
  local -a server_name_lines=()
  local -a certificate_lines=()
  local -a certificate_key_lines=()

  if [[ ! -f "${active_config}" || -L "${active_config}" ]]; then
    finguard_https_error "active Nginx config must be a regular, non-symlink file"
    return 1
  fi

  mapfile -t server_name_lines < <(
    grep -E '^[[:space:]]*server_name[[:space:]]' "${active_config}" || true
  )
  if [[ ${#server_name_lines[@]} -ne 2 ]]; then
    finguard_https_error "HTTPS config must contain exactly two server_name directives"
    return 1
  fi
  for line in "${server_name_lines[@]}"; do
    if [[ "${line}" =~ ^[[:space:]]*server_name[[:space:]]+([^[:space:];]+)[[:space:]]*\;[[:space:]]*(#.*)?$ ]]; then
      value="${BASH_REMATCH[1]}"
    else
      finguard_https_error "HTTPS config contains a malformed server_name directive"
      return 1
    fi
    finguard_validate_https_domain "${value}" || return 1
    if [[ -z "${recovered_domain}" ]]; then
      recovered_domain="${value}"
    elif [[ "${value}" != "${recovered_domain}" ]]; then
      finguard_https_error "HTTPS config contains multiple domains"
      return 1
    fi
  done

  if ! grep -Eq '^[[:space:]]*listen[[:space:]]+(\[::\]:)?443[[:space:]]+ssl([[:space:]]|;)' \
    "${active_config}"; then
    finguard_https_error "config is not an enabled HTTPS site"
    return 1
  fi

  mapfile -t certificate_lines < <(
    grep -E '^[[:space:]]*ssl_certificate[[:space:]]' "${active_config}" || true
  )
  mapfile -t certificate_key_lines < <(
    grep -E '^[[:space:]]*ssl_certificate_key[[:space:]]' "${active_config}" || true
  )
  if [[ ${#certificate_lines[@]} -ne 1 ]]; then
    finguard_https_error "HTTPS config must contain exactly one certificate path"
    return 1
  fi
  if [[ ${#certificate_key_lines[@]} -ne 1 ]]; then
    finguard_https_error "HTTPS config must contain exactly one certificate-key path"
    return 1
  fi

  if [[ ! "${certificate_lines[0]}" =~ ^[[:space:]]*ssl_certificate[[:space:]]+([^[:space:];]+)[[:space:]]*\;[[:space:]]*(#.*)?$ ]]; then
    finguard_https_error "HTTPS config contains a malformed certificate path"
    return 1
  fi
  if [[ "${BASH_REMATCH[1]}" != "/etc/letsencrypt/live/${recovered_domain}/fullchain.pem" ]]; then
    finguard_https_error "HTTPS certificate path does not match the recovered domain"
    return 1
  fi
  if [[ ! "${certificate_key_lines[0]}" =~ ^[[:space:]]*ssl_certificate_key[[:space:]]+([^[:space:];]+)[[:space:]]*\;[[:space:]]*(#.*)?$ ]]; then
    finguard_https_error "HTTPS config contains a malformed certificate-key path"
    return 1
  fi
  if [[ "${BASH_REMATCH[1]}" != "/etc/letsencrypt/live/${recovered_domain}/privkey.pem" ]]; then
    finguard_https_error "HTTPS certificate-key path does not match the recovered domain"
    return 1
  fi

  printf '%s\n' "${recovered_domain}"
}

finguard_render_https_candidate() {
  if [[ $# -ne 3 ]]; then
    finguard_https_error "rendering requires TEMPLATE DOMAIN CANDIDATE"
    return 1
  fi
  local template="$1"
  local domain="$2"
  local candidate="$3"
  local http_prefix=""
  local rendered_domain=""

  finguard_validate_https_domain "${domain}" || return 1
  if [[ ! -f "${template}" || -L "${template}" ]]; then
    finguard_https_error "HTTPS template must be a regular, non-symlink file"
    return 1
  fi
  if [[ -L "${candidate}" ]]; then
    finguard_https_error "candidate path must not be a symlink"
    return 1
  fi
  if ! grep -Fq '__FINGUARD_DOMAIN__' "${template}"; then
    finguard_https_error "HTTPS template is missing its domain placeholder"
    return 1
  fi

  if ! sed "s/__FINGUARD_DOMAIN__/${domain}/g" "${template}" >"${candidate}"; then
    finguard_https_error "failed to render HTTPS template"
    return 1
  fi
  if grep -Fq '__FINGUARD_DOMAIN__' "${candidate}"; then
    finguard_https_error "rendered HTTPS config contains an unresolved domain placeholder"
    return 1
  fi
  rendered_domain="$(finguard_recover_https_domain "${candidate}")" || return 1
  if [[ "${rendered_domain}" != "${domain}" ]]; then
    finguard_https_error "rendered HTTPS identity does not match the requested domain"
    return 1
  fi

  if ! grep -Fq 'limit_req_zone $finguard_ai_limit_key zone=finguard_ai_per_ip:1m rate=2r/m;' \
    "${candidate}"; then
    finguard_https_error "rendered HTTPS config is missing the AI rate limit"
    return 1
  fi
  if ! grep -Fq 'limit_req zone=finguard_ai_per_ip burst=1 nodelay;' "${candidate}"; then
    finguard_https_error "rendered HTTPS config is missing AI endpoint enforcement"
    return 1
  fi
  if ! grep -Fq 'limit_req_zone $finguard_auth_global_limit_key zone=finguard_auth_global:1m rate=30r/m;' \
    "${candidate}"; then
    finguard_https_error "rendered HTTPS config is missing the global auth rate limit"
    return 1
  fi
  if ! grep -Fq 'limit_req zone=finguard_auth_global burst=10 nodelay;' "${candidate}"; then
    finguard_https_error "rendered HTTPS config is missing global auth enforcement"
    return 1
  fi
  if ! grep -Fq "return 308 https://${domain}\$request_uri;" "${candidate}"; then
    finguard_https_error "rendered HTTP server does not redirect to the recovered HTTPS domain"
    return 1
  fi

  http_prefix="$(
    awk '/^[[:space:]]*listen[[:space:]]+(\[::\]:)?443[[:space:]]+ssl([[:space:]]|;)/ { exit }
         { print }' "${candidate}"
  )" || return 1
  if grep -Eq 'proxy_pass|root[[:space:]]+/opt/finguard/web' <<<"${http_prefix}"; then
    finguard_https_error "rendered config exposes the application before the HTTPS server"
    return 1
  fi
}

finguard_validate_certificate_files() {
  if [[ $# -ne 1 ]]; then
    finguard_https_error "certificate validation requires exactly one domain"
    return 1
  fi
  local domain="$1"
  local live_root="/etc/letsencrypt/live"
  local domain_root="${live_root}/${domain}"

  finguard_validate_https_domain "${domain}" || return 1
  if [[ ! -d "${live_root}" || -L "${live_root}" ]]; then
    finguard_https_error "certificate live root must be a directory, not a symlink"
    return 1
  fi
  if [[ ! -d "${domain_root}" || -L "${domain_root}" ]]; then
    finguard_https_error "certificate domain path must be a directory, not a symlink"
    return 1
  fi
  if [[ ! -f "${domain_root}/fullchain.pem" ]]; then
    finguard_https_error "certificate full chain is missing"
    return 1
  fi
  if [[ ! -f "${domain_root}/privkey.pem" ]]; then
    finguard_https_error "certificate private key is missing"
    return 1
  fi
}

finguard_set_https_file_metadata() {
  if [[ $# -ne 1 ]]; then
    finguard_https_error "metadata setup requires exactly one file path"
    return 1
  fi
  local config_path="$1"

  if ! chown root:root "${config_path}"; then
    finguard_https_error "failed to set HTTPS config ownership"
    return 1
  fi
  if ! chmod 0644 "${config_path}"; then
    finguard_https_error "failed to set HTTPS config mode"
    return 1
  fi
}

finguard_replace_https_file() {
  if [[ $# -ne 2 ]]; then
    finguard_https_error "replacement requires CANDIDATE ACTIVE_CONFIG"
    return 1
  fi
  local candidate="$1"
  local active_config="$2"

  mv -fT -- "${candidate}" "${active_config}" || return 1
}

finguard_restore_https_config() (
  set -Eeuo pipefail
  if [[ $# -ne 2 ]]; then
    finguard_https_error "rollback requires BACKUP ACTIVE_CONFIG"
    return 1
  fi
  local backup="$1"
  local active_config="$2"
  local active_dir=""
  local rollback_candidate=""

  active_dir="$(cd -- "$(dirname -- "${active_config}")" && pwd -P)" || return 1
  rollback_candidate="$(mktemp "${active_dir}/.finguard.https.rollback.XXXXXX")" || return 1
  cleanup_https_rollback() {
    rm -f -- "${rollback_candidate}" || true
  }
  trap cleanup_https_rollback EXIT

  if ! cp -- "${backup}" "${rollback_candidate}"; then
    finguard_https_error "failed to prepare the rollback candidate"
    return 1
  fi
  finguard_set_https_file_metadata "${rollback_candidate}" || return 1
  if ! finguard_replace_https_file "${rollback_candidate}" "${active_config}"; then
    finguard_https_error "failed to atomically restore the previous HTTPS config"
    return 1
  fi
  nginx -t || return 1
  systemctl reload nginx || return 1
)

finguard_activate_https_config() (
  set -Eeuo pipefail
  if [[ $# -ne 3 ]]; then
    finguard_https_error "activation requires TEMPLATE ACTIVE_CONFIG DOMAIN"
    return 1
  fi
  local template="$1"
  local active_config="$2"
  local domain="$3"
  local active_dir=""
  local candidate=""
  local backup=""
  local preserve_backup=0

  if [[ ! -f "${active_config}" || -L "${active_config}" ]]; then
    finguard_https_error "active Nginx config must be a regular, non-symlink file"
    return 1
  fi
  finguard_validate_certificate_files "${domain}" || return 1
  active_dir="$(cd -- "$(dirname -- "${active_config}")" && pwd -P)" || return 1
  candidate="$(mktemp "${active_dir}/.finguard.https.candidate.XXXXXX")" || return 1
  backup="$(mktemp "${active_dir}/.finguard.https.backup.XXXXXX")" || return 1

  cleanup_https_activation() {
    rm -f -- "${candidate}"
    if [[ ${preserve_backup} -eq 0 ]]; then
      rm -f -- "${backup}"
    fi
  }
  trap cleanup_https_activation EXIT

  finguard_render_https_candidate "${template}" "${domain}" "${candidate}" || return 1
  finguard_set_https_file_metadata "${candidate}" || return 1
  cp --preserve=mode,ownership,timestamps -- "${active_config}" "${backup}" || return 1
  if ! finguard_replace_https_file "${candidate}" "${active_config}"; then
    finguard_https_error "failed to atomically replace the HTTPS config; active config is unchanged"
    return 1
  fi

  if ! nginx -t; then
    if ! finguard_restore_https_config "${backup}" "${active_config}"; then
      preserve_backup=1
      finguard_https_error \
        "candidate validation and rollback failed; backup preserved at ${backup}"
      return 1
    fi
    finguard_https_error "candidate validation failed; restored and reloaded the previous config"
    return 1
  fi

  if ! systemctl reload nginx; then
    if ! finguard_restore_https_config "${backup}" "${active_config}"; then
      preserve_backup=1
      finguard_https_error \
        "candidate reload and rollback failed; backup preserved at ${backup}"
      return 1
    fi
    finguard_https_error "candidate reload failed; restored and reloaded the previous config"
    return 1
  fi
)

finguard_https_main() {
  if [[ ${EUID} -ne 0 ]]; then
    finguard_https_error "run this script with sudo"
    return 1
  fi
  local script_dir=""
  local deploy_dir=""
  local template=""
  local active_config="/etc/nginx/sites-available/finguard"
  local domain=""

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || return 1
  deploy_dir="$(cd -- "${script_dir}/.." && pwd)" || return 1
  template="${deploy_dir}/nginx/finguard-https.conf.template"

  case "${1-}" in
    --domain)
      if [[ $# -ne 2 ]]; then
        finguard_https_error "usage: $0 --domain DOMAIN"
        return 1
      fi
      domain="$2"
      finguard_validate_https_domain "${domain}" || return 1
      ;;
    --refresh-existing)
      if [[ $# -ne 1 ]]; then
        finguard_https_error "usage: $0 --refresh-existing"
        return 1
      fi
      domain="$(finguard_recover_https_domain "${active_config}")" || return 1
      ;;
    *)
      finguard_https_error "usage: $0 --domain DOMAIN | --refresh-existing"
      return 1
      ;;
  esac

  finguard_activate_https_config "${template}" "${active_config}" "${domain}" || return 1
  printf 'Current HTTPS template activated for %s.\n' "${domain}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  finguard_https_main "$@"
fi
