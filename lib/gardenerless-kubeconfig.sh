# shellcheck shell=bash
# Shared fail-closed validation for gardenerless-managed kubeconfigs.
#
# Callers must set KCP_STATE_DIR and define log_error before sourcing this file.

if [[ -z "${KCP_STATE_DIR:-}" ]] || ! declare -F log_error >/dev/null 2>&1; then
  printf 'Error: gardenerless kubeconfig guard requires KCP_STATE_DIR and log_error.\n' >&2
  return 1
fi

GUARDED_KUBECTL_CANONICAL_KUBECONFIG=""
GUARDED_KUBECTL_KUBECONFIG_DIGEST=""
GUARDED_KUBECTL_RUNTIME_CERT_DIGEST=""

reject_kubectl_connection_overrides() {
  local argument

  for argument in "$@"; do
    case "$argument" in
      --kubeconfig|--kubeconfig=*|\
      --server|--server=*|\
      --context|--context=*|\
      --cluster|--cluster=*|\
      --certificate-authority|--certificate-authority=*|\
      --insecure-skip-tls-verify|--insecure-skip-tls-verify=*|\
      --tls-server-name|--tls-server-name=*|\
      --proxy-url|--proxy-url=*)
        log_error "Error: refusing kubectl connection override '$argument'; guarded kubectl manages the validated target and TLS route."
        return 1
        ;;
    esac
  done
}

guarded_file_digest() {
  local file="${1:-}"

  if [[ $# -ne 1 || -z "$file" || ! -f "$file" || -L "$file" ]]; then
    return 1
  fi

  command openssl dgst -sha256 -binary "$file" 2>/dev/null \
    | command openssl base64 -A 2>/dev/null
}

# Print the canonical path of an explicit, known gardenerless kubeconfig only
# after proving that its current API server is loopback and trusts the selected
# runtime's valid serving certificate bundle.
resolve_and_assert_gardenerless_kubeconfig() {
  local requested_kubeconfig="${1:-}"
  local resolved_state_dir resolved_kubeconfig_dir resolved_kubeconfig
  local runtime_cert server authority hostname
  local insecure_skip_tls_verify tls_server_name proxy_url
  local certificate_authority certificate_authority_data
  local embedded_cert_bundle runtime_cert_bundle subject_alternative_names

  if [[ $# -ne 1 || -z "$requested_kubeconfig" ]]; then
    log_error "Error: pass one explicit gardenerless kubeconfig under '$KCP_STATE_DIR'; ambient KUBECONFIG is ignored."
    return 1
  fi

  if [[ ! -d "$KCP_STATE_DIR" ]]; then
    log_error "Error: gardenerless runtime state directory '$KCP_STATE_DIR' does not exist. Set GARDENERLESS_KCP_DIR to the intended kcp runtime."
    return 1
  fi

  if [[ ! -e "$requested_kubeconfig" ]]; then
    log_error "Error: gardenerless kubeconfig '$requested_kubeconfig' does not exist. Expected a generated kubeconfig under '$KCP_STATE_DIR'."
    return 1
  fi

  if [[ ! -f "$requested_kubeconfig" || -L "$requested_kubeconfig" ]]; then
    log_error "Error: gardenerless kubeconfig '$requested_kubeconfig' must be a regular, non-symlink file."
    return 1
  fi

  if ! resolved_state_dir=$(cd -- "$KCP_STATE_DIR" 2>/dev/null && pwd -P); then
    log_error "Error: cannot resolve gardenerless runtime state directory '$KCP_STATE_DIR'."
    return 1
  fi

  if ! resolved_kubeconfig_dir=$(cd -- "$(dirname -- "$requested_kubeconfig")" 2>/dev/null && pwd -P); then
    log_error "Error: cannot resolve the directory containing gardenerless kubeconfig '$requested_kubeconfig'."
    return 1
  fi
  resolved_kubeconfig="${resolved_kubeconfig_dir}/$(basename -- "$requested_kubeconfig")"

  case "$resolved_kubeconfig" in
    "$resolved_state_dir/admin.kubeconfig"|\
    "$resolved_state_dir/dashboard-kcp.kubeconfig"|\
    "$resolved_state_dir/dashboard.kubeconfig")
      ;;
    *)
      log_error "Error: refusing unknown or out-of-runtime kubeconfig '$requested_kubeconfig'. Use a gardenerless-generated kubeconfig directly under '$KCP_STATE_DIR'."
      return 1
      ;;
  esac

  if ! command -v kubectl >/dev/null 2>&1; then
    log_error "Error: kubectl is required to validate gardenerless kubeconfig '$resolved_kubeconfig'."
    return 1
  fi

  if ! server=$(command kubectl --kubeconfig="$resolved_kubeconfig" config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null); then
    log_error "Error: cannot read the current API server from gardenerless kubeconfig '$resolved_kubeconfig'. Check its YAML, current-context, and cluster reference."
    return 1
  fi

  if [[ -z "$server" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' has no API server for its current context."
    return 1
  fi

  if [[ "$server" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]+)([/?#].*)?$ ]]; then
    authority="${BASH_REMATCH[1]}"
  else
    log_error "Error: API server '$server' in '$resolved_kubeconfig' is not a valid absolute URL."
    return 1
  fi

  if [[ "$authority" == *"@"* ]]; then
    log_error "Error: API server '$server' in '$resolved_kubeconfig' contains user information and is not an allowed loopback target."
    return 1
  elif [[ "$authority" =~ ^\[([^]]+)\](:[0-9]+)?$ ]]; then
    hostname="${BASH_REMATCH[1]}"
  elif [[ "$authority" =~ ^([^:]+)(:[0-9]+)?$ ]]; then
    hostname="${BASH_REMATCH[1]}"
  else
    log_error "Error: cannot extract a valid hostname from API server '$server' in '$resolved_kubeconfig'."
    return 1
  fi

  case "$hostname" in
    localhost|127.0.0.1|::1)
      ;;
    *)
      log_error "Error: refusing API server '$server' from '$resolved_kubeconfig'. Hostname '$hostname' is not exactly localhost, 127.0.0.1, or ::1."
      return 1
      ;;
  esac

  if [[ "$server" != https://* ]]; then
    log_error "Error: refusing non-HTTPS API server '$server' from '$resolved_kubeconfig'. Gardenerless kubeconfigs must use TLS."
    return 1
  fi

  if ! insecure_skip_tls_verify=$(command kubectl --kubeconfig="$resolved_kubeconfig" config view --raw --minify -o 'jsonpath={.clusters[0].cluster.insecure-skip-tls-verify}' 2>/dev/null) || \
     ! tls_server_name=$(command kubectl --kubeconfig="$resolved_kubeconfig" config view --raw --minify -o 'jsonpath={.clusters[0].cluster.tls-server-name}' 2>/dev/null) || \
     ! proxy_url=$(command kubectl --kubeconfig="$resolved_kubeconfig" config view --raw --minify -o 'jsonpath={.clusters[0].cluster.proxy-url}' 2>/dev/null) || \
     ! certificate_authority=$(command kubectl --kubeconfig="$resolved_kubeconfig" config view --raw --minify -o 'jsonpath={.clusters[0].cluster.certificate-authority}' 2>/dev/null) || \
     ! certificate_authority_data=$(command kubectl --kubeconfig="$resolved_kubeconfig" config view --raw --minify -o 'jsonpath={.clusters[0].cluster.certificate-authority-data}' 2>/dev/null); then
    log_error "Error: cannot inspect TLS settings in gardenerless kubeconfig '$resolved_kubeconfig'."
    return 1
  fi

  if [[ "$insecure_skip_tls_verify" == "true" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' disables TLS certificate verification."
    return 1
  fi

  if [[ -n "$tls_server_name" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' overrides the TLS server name with '$tls_server_name'. Remove tls-server-name so the loopback hostname is verified."
    return 1
  fi

  if [[ -n "$proxy_url" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' routes requests through proxy '$proxy_url'. Gardenerless kubeconfigs must connect directly to loopback."
    return 1
  fi

  if [[ -n "$certificate_authority" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' references external certificate authority '$certificate_authority'. Expected embedded runtime certificate data."
    return 1
  fi

  if [[ -z "$certificate_authority_data" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' has no embedded certificate authority data."
    return 1
  fi

  runtime_cert="${resolved_state_dir}/apiserver.crt"
  if [[ ! -e "$runtime_cert" ]]; then
    log_error "Error: gardenerless runtime certificate '$runtime_cert' does not exist. Start kcp once to generate the local serving certificate."
    return 1
  fi

  if [[ ! -f "$runtime_cert" || -L "$runtime_cert" ]]; then
    log_error "Error: gardenerless runtime certificate '$runtime_cert' must be a regular, non-symlink file."
    return 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    log_error "Error: openssl is required to validate the gardenerless runtime certificate '$runtime_cert'."
    return 1
  fi

  if ! embedded_cert_bundle=$(printf '%s' "$certificate_authority_data" | command openssl base64 -d -A 2>/dev/null) || [[ -z "$embedded_cert_bundle" ]]; then
    log_error "Error: gardenerless kubeconfig '$resolved_kubeconfig' contains invalid embedded certificate data."
    return 1
  fi

  if ! runtime_cert_bundle=$(<"$runtime_cert") || [[ -z "$runtime_cert_bundle" ]]; then
    log_error "Error: cannot read gardenerless runtime certificate '$runtime_cert'."
    return 1
  fi

  if [[ "$embedded_cert_bundle" != "$runtime_cert_bundle" ]]; then
    log_error "Error: certificate data in gardenerless kubeconfig '$resolved_kubeconfig' does not match local runtime certificate '$runtime_cert'."
    return 1
  fi

  if ! command openssl crl2pkcs7 -nocrl -certfile "$runtime_cert" 2>/dev/null \
      | command openssl pkcs7 -print_certs -text 2>/dev/null \
      | grep -q 'CA:TRUE'; then
    log_error "Error: gardenerless runtime certificate '$runtime_cert' does not contain a valid certificate authority."
    return 1
  fi

  if ! command openssl verify -CAfile "$runtime_cert" -purpose sslserver "$runtime_cert" >/dev/null 2>&1; then
    log_error "Error: gardenerless runtime certificate '$runtime_cert' has an invalid or expired server certificate chain."
    return 1
  fi

  if ! subject_alternative_names=$(command openssl x509 -in "$runtime_cert" -noout -ext subjectAltName 2>/dev/null) || \
     [[ "$subject_alternative_names" != *"Subject Alternative Name"* ]]; then
    log_error "Error: gardenerless runtime certificate '$runtime_cert' has no subject alternative names."
    return 1
  fi

  case "$hostname" in
    localhost)
      if ! command openssl x509 -in "$runtime_cert" -noout -checkhost "$hostname" >/dev/null 2>&1; then
        log_error "Error: gardenerless runtime certificate '$runtime_cert' is not valid for loopback hostname '$hostname'."
        return 1
      fi
      ;;
    127.0.0.1|::1)
      if ! command openssl x509 -in "$runtime_cert" -noout -checkip "$hostname" >/dev/null 2>&1; then
        log_error "Error: gardenerless runtime certificate '$runtime_cert' is not valid for loopback address '$hostname'."
        return 1
      fi
      ;;
  esac

  printf '%s\n' "$resolved_kubeconfig"
}

cache_guarded_kubeconfig() {
  local requested_kubeconfig="${1:-}"
  local runtime_cert="${KCP_STATE_DIR}/apiserver.crt"
  local kubeconfig_digest_before cert_digest_before
  local canonical_kubeconfig kubeconfig_digest_after cert_digest_after

  if [[ $# -ne 1 || -z "$requested_kubeconfig" ]]; then
    log_error "Error: guarded kubectl requires one explicit gardenerless kubeconfig."
    return 1
  fi

  if ! kubeconfig_digest_before=$(guarded_file_digest "$requested_kubeconfig") || \
     ! cert_digest_before=$(guarded_file_digest "$runtime_cert"); then
    log_error "Error: cannot fingerprint gardenerless kubeconfig '$requested_kubeconfig' and runtime certificate '$runtime_cert'."
    return 1
  fi

  if ! canonical_kubeconfig=$(resolve_and_assert_gardenerless_kubeconfig "$requested_kubeconfig"); then
    return 1
  fi

  if ! kubeconfig_digest_after=$(guarded_file_digest "$canonical_kubeconfig") || \
     ! cert_digest_after=$(guarded_file_digest "$runtime_cert"); then
    log_error "Error: cannot fingerprint validated gardenerless kubeconfig '$canonical_kubeconfig' and runtime certificate '$runtime_cert'."
    return 1
  fi

  if [[ "$kubeconfig_digest_before" != "$kubeconfig_digest_after" || \
        "$cert_digest_before" != "$cert_digest_after" ]]; then
    log_error "Error: gardenerless kubeconfig or runtime certificate changed during validation; refusing kubectl invocation."
    return 1
  fi

  GUARDED_KUBECTL_CANONICAL_KUBECONFIG="$canonical_kubeconfig"
  GUARDED_KUBECTL_KUBECONFIG_DIGEST="$kubeconfig_digest_after"
  GUARDED_KUBECTL_RUNTIME_CERT_DIGEST="$cert_digest_after"
}

guarded_kubeconfig_cache_matches() {
  local requested_kubeconfig="${1:-}"
  local runtime_cert="${KCP_STATE_DIR}/apiserver.crt"
  local kubeconfig_digest cert_digest

  if [[ $# -ne 1 || -z "$GUARDED_KUBECTL_CANONICAL_KUBECONFIG" || \
        "$requested_kubeconfig" != "$GUARDED_KUBECTL_CANONICAL_KUBECONFIG" ]]; then
    return 1
  fi

  if ! kubeconfig_digest=$(guarded_file_digest "$requested_kubeconfig") || \
     ! cert_digest=$(guarded_file_digest "$runtime_cert"); then
    return 1
  fi

  [[ "$kubeconfig_digest" == "$GUARDED_KUBECTL_KUBECONFIG_DIGEST" && \
     "$cert_digest" == "$GUARDED_KUBECTL_RUNTIME_CERT_DIGEST" ]]
}

# Invoke kubectl with both explicit guarded kubeconfig mechanisms. Callers can
# select an absolute kubectl-ws binary so its containing directory does not
# need to be exposed through PATH.
invoke_guarded_kubectl() {
  local canonical_kubeconfig="${1:-}"

  if [[ $# -lt 2 || -z "$canonical_kubeconfig" ]]; then
    log_error "Error: guarded kubectl invocation requires a canonical kubeconfig and command."
    return 1
  fi
  shift

  if [[ "$1" == "ws" ]]; then
    shift
    if [[ -n "${KCP_KUBECTL_WS_BINARY:-}" ]]; then
      if [[ ! -x "$KCP_KUBECTL_WS_BINARY" ]]; then
        log_error "Error: kubectl workspace plugin '$KCP_KUBECTL_WS_BINARY' is missing or not executable."
        return 1
      fi
      KUBECONFIG="$canonical_kubeconfig" \
        command "$KCP_KUBECTL_WS_BINARY" --kubeconfig="$canonical_kubeconfig" "$@"
    else
      # Generic callers can continue using kubectl's standard plugin lookup.
      KUBECONFIG="$canonical_kubeconfig" \
        command kubectl ws --kubeconfig="$canonical_kubeconfig" "$@"
    fi
  else
    KUBECONFIG="$canonical_kubeconfig" \
      command kubectl --kubeconfig="$canonical_kubeconfig" "$@"
  fi
}

# Validate an explicit allow-listed kubeconfig and invoke kubectl through it.
# Cached validation is reused only while both the kubeconfig and runtime
# certificate remain byte-for-byte unchanged.
guarded_kubectl() {
  local requested_kubeconfig="${1:-}"
  local canonical_kubeconfig

  if [[ $# -lt 2 || -z "$requested_kubeconfig" ]]; then
    log_error "Error: guarded kubectl requires an explicit kubeconfig and command."
    return 1
  fi
  shift

  if ! reject_kubectl_connection_overrides "$@"; then
    return 1
  fi

  if ! guarded_kubeconfig_cache_matches "$requested_kubeconfig"; then
    if ! cache_guarded_kubeconfig "$requested_kubeconfig"; then
      return 1
    fi
  fi
  canonical_kubeconfig="$GUARDED_KUBECTL_CANONICAL_KUBECONFIG"

  invoke_guarded_kubectl "$canonical_kubeconfig" "$@"
}
