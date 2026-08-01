#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
GARDENERLESS_SETUP="${SCRIPT_DIR}/gardenerless-setup.sh"
KUBECTL_GARDENERLESS="${SCRIPT_DIR}/kubectl-gardenerless"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gardenerless-guard-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

RUNTIME_DIR="${TEST_TMP}/runtime"
STATE_DIR="${RUNTIME_DIR}/.kcp"
STUB_BIN="${TEST_TMP}/bin"
KUBECTL_LOG="${TEST_TMP}/kubectl.log"
WORKSPACE_PLUGIN_LOG="${TEST_TMP}/workspace-plugin.log"
PROCESS_LOG="${TEST_TMP}/process.log"
COMMAND_OUTPUT="${TEST_TMP}/command.out"
ADMIN_KUBECONFIG="${STATE_DIR}/admin.kubeconfig"
DASHBOARD_KUBECONFIG="${STATE_DIR}/dashboard.kubeconfig"
AMBIENT_KUBECONFIG="${TEST_TMP}/ambient.kubeconfig"
RUNTIME_CERT="${STATE_DIR}/apiserver.crt"
VALID_SERVER="https://127.0.0.1:6443"
REJECTED_SERVER="https://api.example.invalid:6443"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_no_api_calls() {
  if grep -q '^api|' "$KUBECTL_LOG"; then
    printf 'Unexpected API-facing kubectl calls:\n' >&2
    grep '^api|' "$KUBECTL_LOG" >&2
    fail "$1"
  fi
}

assert_api_calls_use_guarded_kubeconfig() {
  local description="$1" api_call

  while IFS= read -r api_call; do
    if [[ "$api_call" == *"|kubeconfig=${CANONICAL_DASHBOARD_KUBECONFIG}|"* ]]; then
      [[ "$api_call" == *"|env=${CANONICAL_DASHBOARD_KUBECONFIG}|"* ]] \
        || fail "$description dashboard capability call did not receive canonical KUBECONFIG: $api_call"
      [[ "$api_call" == *"<get><projects.core.gardener.cloud><-o><name>"* ]] \
        || fail "$description used the dashboard kubeconfig outside its Projects capability probe: $api_call"
    else
      [[ "$api_call" == *"|env=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
        || fail "$description API call did not receive canonical KUBECONFIG: $api_call"
      [[ "$api_call" == *"|kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
        || fail "$description API call did not receive canonical --kubeconfig: $api_call"
    fi
    [[ "$api_call" != *"$AMBIENT_KUBECONFIG"* ]] \
      || fail "ambient KUBECONFIG redirected a $description API call: $api_call"
  done < <(grep '^api|' "$KUBECTL_LOG")
}

test_yq_read() {
  local expression="$1" file="$2"

  if yq --version 2>/dev/null | grep -qiE 'mikefarah|version v?[0-9]+\.'; then
    yq e "$expression" "$file"
  else
    yq -r "$expression" "$file"
  fi
}

run_setup() {
  env \
    PATH="${STUB_BIN}:$PATH" \
    GARDENERLESS_KCP_DIR="$RUNTIME_DIR" \
    KUBECTL_LOG="$KUBECTL_LOG" \
    WORKSPACE_PLUGIN_LOG="$WORKSPACE_PLUGIN_LOG" \
    PROCESS_LOG="$PROCESS_LOG" \
    STUB_PROCESS_STATE="${STUB_PROCESS_STATE:-stopped}" \
    STUB_API_READY="${STUB_API_READY:-ready}" \
    STUB_DEMO_STATE="${STUB_DEMO_STATE:-}" \
    STUB_DASHBOARD_PROJECTS_ACCESS="${STUB_DASHBOARD_PROJECTS_ACCESS:-ready}" \
    STUB_ROOT_SWITCH="${STUB_ROOT_SWITCH:-ready}" \
    STUB_EXISTING_CRD_NAMES="${STUB_EXISTING_CRD_NAMES-__inherit__}" \
    STUB_CRD_GET_FAILURE="${STUB_CRD_GET_FAILURE:-}" \
    STUB_DASHBOARD_KUBECONFIG="$CANONICAL_DASHBOARD_KUBECONFIG" \
    STUB_KUBECTL_BINARY="${STUB_BIN}/kubectl" \
    STUB_CERT_FILE="$RUNTIME_CERT" \
    STUB_SERVER="${STUB_SERVER_OVERRIDE:-$VALID_SERVER}" \
    STUB_SERVER_AFTER_CONTEXT_CHANGE="${STUB_SERVER_AFTER_CONTEXT_CHANGE:-}" \
    KUBECONFIG="$AMBIENT_KUBECONFIG" \
    "$GARDENERLESS_SETUP" "$@"
}

run_kubectl_gardenerless() {
  env \
    PATH="${STUB_BIN}:$PATH" \
    GARDENERLESS_KCP_DIR="$RUNTIME_DIR" \
    KUBECTL_LOG="$KUBECTL_LOG" \
    STUB_CERT_FILE="$RUNTIME_CERT" \
    STUB_SERVER="${STUB_SERVER_OVERRIDE:-$VALID_SERVER}" \
    KUBECONFIG="$AMBIENT_KUBECONFIG" \
    "$KUBECTL_GARDENERLESS" "$@"
}

assert_rejected_before_api() {
  : >"$KUBECTL_LOG"
  if STUB_SERVER_OVERRIDE="$REJECTED_SERVER" run_setup "$@" >"$COMMAND_OUTPUT" 2>&1; then
    fail "rejected kubeconfig unexpectedly allowed command: $*"
  fi
  assert_no_api_calls "rejected kubeconfig reached the API for command: $*"
}

assert_wrapper_override_rejected() {
  : >"$KUBECTL_LOG"
  if run_kubectl_gardenerless "$@" >"$COMMAND_OUTPUT" 2>&1; then
    fail "kubectl-gardenerless accepted connection override: $*"
  fi
  [[ ! -s "$KUBECTL_LOG" ]] \
    || fail "kubectl-gardenerless invoked kubectl for rejected override: $*"
}

for dependency in openssl yq; do
  command -v "$dependency" >/dev/null 2>&1 || fail "required test dependency not found: $dependency"
done

mkdir -p "$STATE_DIR" "$STUB_BIN"
mkdir -p "${RUNTIME_DIR}/bin"
: >"$WORKSPACE_PLUGIN_LOG"

cat >"${TEST_TMP}/openssl.cnf" <<'EOF'
[req]
distinguished_name = distinguished_name
x509_extensions = gardenerless_cert
prompt = no

[distinguished_name]
CN = gardenerless-test

[gardenerless_cert]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign
extendedKeyUsage = serverAuth
subjectAltName = @subject_alternative_names

[subject_alternative_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 2 \
  -keyout "${TEST_TMP}/apiserver.key" \
  -out "$RUNTIME_CERT" \
  -config "${TEST_TMP}/openssl.cnf" \
  >/dev/null 2>&1

cat >"$ADMIN_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
current-context: root
clusters:
- name: gardenerless
  cluster:
    server: $VALID_SERVER
contexts:
- name: root
  context:
    cluster: gardenerless
EOF

cat >"$AMBIENT_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: ambient
  cluster:
    server: $REJECTED_SERVER
EOF

cat >"${STUB_BIN}/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == --kubeconfig=* && "${2:-}" == "ws" ]]; then
  printf 'flags cannot be placed before plugin name: %s\n' "$1" >&2
  exit 1
fi

kubeconfig=""
is_config=false
forwarded_args=()
for arg in "$@"; do
  case "$arg" in
    --kubeconfig=*)
      kubeconfig="${arg#--kubeconfig=}"
      ;;
    config)
      is_config=true
      ;;
    *)
      forwarded_args+=("$arg")
      ;;
  esac
done

forwarded_string=" ${forwarded_args[*]} "

if "$is_config"; then
  kind="config"
else
  kind="api"
fi

{
  printf '%s|env=%s|kubeconfig=%s|args=' "$kind" "${KUBECONFIG:-}" "$kubeconfig"
  printf '<%s>' "$@"
  printf '\n'
} >>"$KUBECTL_LOG"

if "$is_config"; then
  case "$*" in
    *'.clusters[0].cluster.server}'*)
      if [[ -n "${STUB_SERVER_AFTER_CONTEXT_CHANGE:-}" ]] && \
         grep -q '^# stub-context-changed$' "$kubeconfig"; then
        printf '%s' "$STUB_SERVER_AFTER_CONTEXT_CHANGE"
      else
        printf '%s' "$STUB_SERVER"
      fi
      ;;
    *'.clusters[0].cluster.certificate-authority-data}'*)
      openssl base64 -A -in "$STUB_CERT_FILE"
      ;;
    *'.clusters[0].cluster.insecure-skip-tls-verify}'*|\
    *'.clusters[0].cluster.tls-server-name}'*|\
    *'.clusters[0].cluster.proxy-url}'*|\
    *'.clusters[0].cluster.certificate-authority}'*)
      ;;
    *'current-context'*)
      printf 'root\n'
      ;;
    *'use-context'*)
      if [[ -n "${STUB_SERVER_AFTER_CONTEXT_CHANGE:-}" ]]; then
        printf '\n# stub-context-changed\n' >>"$kubeconfig"
      fi
      ;;
  esac
elif [[ "${STUB_API_READY:-ready}" != "ready" ]]; then
  exit 1
elif [[ "${STUB_DASHBOARD_PROJECTS_ACCESS:-ready}" != "ready" && \
        "$kubeconfig" == "$STUB_DASHBOARD_KUBECONFIG" && \
        "$forwarded_string" == *" get projects.core.gardener.cloud -o name "* ]]; then
  exit 1
elif [[ "${STUB_ROOT_SWITCH:-ready}" != "ready" && \
        "$forwarded_string" == *" ws :root "* ]]; then
  exit 1
elif [[ "$forwarded_string" == *" get customresourcedefinition "* && \
        "${STUB_EXISTING_CRD_NAMES-__inherit__}" != "__inherit__" ]]; then
  crd_name="${forwarded_args[2]:-}"
  if [[ -n "${STUB_CRD_GET_FAILURE:-}" && \
        "$crd_name" == "$STUB_CRD_GET_FAILURE" ]]; then
    exit 1
  fi
  for existing_crd_name in ${STUB_EXISTING_CRD_NAMES:-}; do
    if [[ "$crd_name" == "$existing_crd_name" ]]; then
      printf 'customresourcedefinition.apiextensions.k8s.io/%s\n' "$crd_name"
      break
    fi
  done
  exit 0
elif [[ "${STUB_DEMO_STATE:-}" == "missing" && "$forwarded_string" == *" ws :root:demo "* ]]; then
  exit 1
elif [[ "${STUB_DEMO_STATE:-}" == "missing" && "$forwarded_string" == *" get "* ]]; then
  # kubectl get --ignore-not-found succeeds with empty output for an absent
  # object. This lets the fixture exercise only-create-if-missing behavior.
  exit 0
elif [[ "${STUB_DEMO_STATE:-}" == "healthy" && "$forwarded_string" == *" get "* ]]; then
  printf 'fixture/resource\n'
fi
EOF
chmod +x "${STUB_BIN}/kubectl"

cat >"${RUNTIME_DIR}/bin/kubectl-ws" <<'EOF'
#!/bin/bash
set -euo pipefail

printf 'runtime-plugin|args=' >>"$WORKSPACE_PLUGIN_LOG"
printf '<%s>' "$@" >>"$WORKSPACE_PLUGIN_LOG"
printf '\n' >>"$WORKSPACE_PLUGIN_LOG"
exec "$STUB_KUBECTL_BINARY" ws "$@"
EOF
chmod +x "${RUNTIME_DIR}/bin/kubectl-ws"

cat >"${STUB_BIN}/pgrep" <<'EOF'
#!/bin/bash
set -euo pipefail

{
  printf 'pgrep|args='
  printf '<%s>' "$@"
  printf '\n'
} >>"$PROCESS_LOG"

if [[ "${STUB_PROCESS_STATE:-stopped}" == "running" ]]; then
  printf '4242\n'
  exit 0
fi

exit 1
EOF
chmod +x "${STUB_BIN}/pgrep"

cat >"${RUNTIME_DIR}/bin/kcp" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "${RUNTIME_DIR}/bin/kcp"

CANONICAL_STATE_DIR="$(cd -- "$STATE_DIR" && pwd -P)"
CANONICAL_ADMIN_KUBECONFIG="${CANONICAL_STATE_DIR}/admin.kubeconfig"
CANONICAL_DASHBOARD_KUBECONFIG="${CANONICAL_STATE_DIR}/dashboard.kubeconfig"

# Every currently dispatched API-facing command must fail before its body when
# the selected gardenerless kubeconfig is rejected.
assert_rejected_before_api setup-gardener-crds
assert_rejected_before_api cluster-resources
assert_rejected_before_api get-token
assert_rejected_before_api create-demo-workspaces
assert_rejected_before_api ensure-single-demo-workspace
assert_rejected_before_api scenario healthy-shoot
assert_rejected_before_api add-project --name guarded
assert_rejected_before_api add-shoot --shoot guarded --project guarded
assert_rejected_before_api add-projects --count 1
assert_rejected_before_api add-shoots --project guarded --count 1

# A missing explicit admin kubeconfig also fails without an API-facing call.
mv "$ADMIN_KUBECONFIG" "${ADMIN_KUBECONFIG}.saved"
: >"$KUBECTL_LOG"
if run_setup get-token >"$COMMAND_OUTPUT" 2>&1; then
  fail "missing admin kubeconfig unexpectedly allowed get-token"
fi
assert_no_api_calls "missing admin kubeconfig reached the API"
mv "${ADMIN_KUBECONFIG}.saved" "$ADMIN_KUBECONFIG"

# Workspace selection is API-facing and cannot run before validation.
: >"$KUBECTL_LOG"
if STUB_SERVER_OVERRIDE="$REJECTED_SERVER" \
    run_setup --workspace guarded get-token >"$COMMAND_OUTPUT" 2>&1; then
  fail "rejected kubeconfig unexpectedly allowed workspace selection"
fi
assert_no_api_calls "workspace selection ran before validation"

# A context mutation invalidates the shared validation cache. The next
# API-facing call must revalidate the newly selected target and reject it.
cp "$ADMIN_KUBECONFIG" "${ADMIN_KUBECONFIG}.before-context-test"
: >"$KUBECTL_LOG"
if STUB_SERVER_AFTER_CONTEXT_CHANGE="$REJECTED_SERVER" \
    run_setup --workspace guarded get-token >"$COMMAND_OUTPUT" 2>&1; then
  fail "context mutation unexpectedly retained stale guarded validation"
fi
assert_no_api_calls "context mutation reached the API before revalidation"
grep -Fq "refusing API server '$REJECTED_SERVER'" "$COMMAND_OUTPUT" \
  || fail "context mutation did not revalidate and reject the changed target"
server_validation_count="$(
  grep -c "^config|.*<config><view><--minify><-o><jsonpath={.clusters\\[0\\].cluster.server}>" "$KUBECTL_LOG"
)"
[[ "$server_validation_count" -ge 2 ]] \
  || fail "context mutation did not trigger a second target validation"
mv "${ADMIN_KUBECONFIG}.before-context-test" "$ADMIN_KUBECONFIG"

# A valid command dispatch uses only the canonical asserted kubeconfig for
# workspace selection and the final API request, ignoring ambient KUBECONFIG.
: >"$KUBECTL_LOG"
: >"$WORKSPACE_PLUGIN_LOG"
run_setup --workspace guarded get-token >"$COMMAND_OUTPUT" 2>&1
grep -q '^runtime-plugin|' "$WORKSPACE_PLUGIN_LOG" \
  || fail "workspace selection did not invoke the runtime plugin by explicit path"
grep -q '^api|.*<ws>' "$KUBECTL_LOG" || fail "valid workspace selection did not run"
grep -q '^api|.*<create><token>' "$KUBECTL_LOG" || fail "valid get-token dispatch did not run"
grep -q "^api|.*<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><:root>" "$KUBECTL_LOG" \
  || fail "workspace plugin did not receive canonical --kubeconfig after its plugin name"
while IFS= read -r api_call; do
  [[ "$api_call" == *"|env=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
    || fail "API call did not receive the canonical admin KUBECONFIG: $api_call"
  [[ "$api_call" == *"|kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
    || fail "API call did not receive the canonical admin --kubeconfig: $api_call"
  [[ "$api_call" != *"$AMBIENT_KUBECONFIG"* ]] \
    || fail "ambient KUBECONFIG redirected an API call: $api_call"
done < <(grep '^api|' "$KUBECTL_LOG")

first_api_line="$(grep -n '^api|' "$KUBECTL_LOG" | head -n 1 | cut -d: -f1)"
config_calls_before_api="$(sed -n "1,$((first_api_line - 1))p" "$KUBECTL_LOG" | grep -c '^config|')"
[[ "$config_calls_before_api" -ge 6 ]] \
  || fail "API dispatch occurred before the shared assertion completed"

# The upstream selectable service-account behavior remains available through
# the same guarded get-token dispatch.
: >"$KUBECTL_LOG"
run_setup get-token --service-account landscape-viewer >"$COMMAND_OUTPUT" 2>&1
grep -q '^api|.*<-n><garden><create><token><landscape-viewer><--duration><24h>' "$KUBECTL_LOG" \
  || fail "get-token did not forward the selected service account"
assert_api_calls_use_guarded_kubeconfig "selected service-account token"

# Help documents only dispatched commands. The removed legacy command is not a
# compatibility path: it fails as an unknown command before any API request.
: >"$KUBECTL_LOG"
run_setup --help >"$COMMAND_OUTPUT" 2>&1
grep -Fq 'ensure-single-demo-workspace' "$COMMAND_OUTPUT" \
  || fail "help did not document ensure-single-demo-workspace"
grep -Fq 'operation-in-progress' "$COMMAND_OUTPUT" \
  || fail "help did not document named scenarios"
if grep -Eq 'create-single-demo-workspace|toggle-shoot-status|random-update-shoots|simulate-shoot-op' "$COMMAND_OUTPUT"; then
  fail "help advertised a removed or undispatched command"
fi
[[ ! -s "$KUBECTL_LOG" ]] || fail "help invoked kubectl"

: >"$KUBECTL_LOG"
if run_setup create-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1; then
  fail "removed create-single-demo-workspace command unexpectedly succeeded"
fi
grep -Fq 'Unknown command: create-single-demo-workspace' "$COMMAND_OUTPUT" \
  || fail "removed create-single-demo-workspace command did not fail as unknown"
assert_no_api_calls "removed create-single-demo-workspace reached the API"

# Purely local help and dashboard-kubeconfigs remain usable without assertion
# or workspace selection, even when an ambient kubeconfig is present.
: >"$KUBECTL_LOG"
run_setup --help >"$COMMAND_OUTPUT" 2>&1
[[ ! -s "$KUBECTL_LOG" ]] || fail "help invoked kubectl"

: >"$KUBECTL_LOG"
run_setup --workspace ignored dashboard-kubeconfigs >"$COMMAND_OUTPUT" 2>&1
[[ ! -s "$KUBECTL_LOG" ]] || fail "dashboard-kubeconfigs invoked kubectl"
grep -Fq "$DASHBOARD_KUBECONFIG" "$COMMAND_OUTPUT" \
  || fail "dashboard-kubeconfigs did not report the generated path"

# setup-kcp must not report a successful build after its clone command fails.
# This test uses a separate stub path so the API guard fixtures remain
# independent from the local-only setup behavior.
SETUP_STUB_BIN="${TEST_TMP}/setup-bin"
SETUP_RUNTIME="${TEST_TMP}/setup-runtime"
mkdir -p "$SETUP_STUB_BIN"
cat >"${SETUP_STUB_BIN}/git" <<'EOF'
#!/bin/bash
printf 'simulated clone failure\n' >&2
exit 1
EOF
chmod +x "${SETUP_STUB_BIN}/git"

if env \
    PATH="${SETUP_STUB_BIN}:/usr/bin:/bin" \
    GARDENERLESS_KCP_DIR="$SETUP_RUNTIME" \
    "$GARDENERLESS_SETUP" setup-kcp >"$COMMAND_OUTPUT" 2>&1; then
  fail "setup-kcp reported success after its clone command failed"
fi
if grep -Fq 'kcp built successfully' "$COMMAND_OUTPUT"; then
  fail "setup-kcp printed build success after its clone command failed"
fi

# Status remains useful with an absent runtime and without kubectl workspace
# plugins. It is read-only and must not try an API request without a valid
# explicit gardenerless kubeconfig.
: >"$KUBECTL_LOG"
env \
  PATH="${STUB_BIN}:/usr/bin:/bin" \
  GARDENERLESS_KCP_DIR="${TEST_TMP}/missing-runtime" \
  KUBECTL_LOG="$KUBECTL_LOG" \
  PROCESS_LOG="$PROCESS_LOG" \
  STUB_CERT_FILE="$RUNTIME_CERT" \
  STUB_SERVER="$VALID_SERVER" \
  KUBECONFIG="$AMBIENT_KUBECONFIG" \
  "$GARDENERLESS_SETUP" status >"$COMMAND_OUTPUT" 2>&1
grep -Eq '^Runtime state:[[:space:]]+absent$' "$COMMAND_OUTPUT" \
  || fail "status did not report an absent runtime"
grep -Eq '^  kubectl workspace plugin:[[:space:]]+missing$' "$COMMAND_OUTPUT" \
  || fail "status did not report a missing kubectl workspace plugin"
grep -Eq '^API readiness:[[:space:]]+unavailable \(explicit kubeconfig validation failed; no API request was made\)$' "$COMMAND_OUTPUT" \
  || fail "status did not explain the missing guarded kubeconfig"
[[ ! -s "$KUBECTL_LOG" ]] || fail "status contacted kubectl with an absent runtime"

# A stopped kcp process and unavailable API are reported without failing. The
# status command stops after its guarded readiness probe and skips the resource
# summary requests when that probe fails.
: >"$KUBECTL_LOG"
: >"$PROCESS_LOG"
STUB_PROCESS_STATE=stopped STUB_API_READY=unavailable \
  run_setup status >"$COMMAND_OUTPUT" 2>&1
grep -Eq '^kcp process:[[:space:]]+stopped$' "$COMMAND_OUTPUT" \
  || fail "status did not report a stopped kcp process"
grep -q '^pgrep|' "$PROCESS_LOG" || fail "status did not use the process stub"
grep -Eq '^API readiness:[[:space:]]+unavailable$' "$COMMAND_OUTPUT" \
  || fail "status did not report an unavailable API"
grep -Eq '^Demo resources:[[:space:]]+unavailable \(API is not ready\)$' "$COMMAND_OUTPUT" \
  || fail "status did not skip demo-resource inspection when the API was unavailable"
grep -q '^api|.*<get><--raw=/readyz>' "$KUBECTL_LOG" \
  || fail "status did not make its guarded readiness probe"
if grep -q '^api|.*<get><projects>' "$KUBECTL_LOG"; then
  fail "status queried demo resources after a failed readiness probe"
fi

# Rejected kubeconfigs still return a useful status report, but they must not
# reach the API readiness or demo-resource requests.
: >"$KUBECTL_LOG"
STUB_SERVER_OVERRIDE="$REJECTED_SERVER" run_setup status >"$COMMAND_OUTPUT" 2>&1
grep -Eq '^API readiness:[[:space:]]+unavailable \(explicit kubeconfig validation failed; no API request was made\)$' "$COMMAND_OUTPUT" \
  || fail "status did not report rejected kubeconfig validation"
assert_no_api_calls "rejected kubeconfig reached the API through status"

# A guarded successful status uses the canonical admin kubeconfig, ignores an
# ambient KUBECONFIG, derives the selected workspace locally, and never runs
# mutating or workspace-changing commands even when --workspace is supplied.
: >"$KUBECTL_LOG"
: >"$PROCESS_LOG"
STUB_PROCESS_STATE=running \
  STUB_SERVER_OVERRIDE="${VALID_SERVER}/clusters/root:demo" \
  run_setup --workspace ignored status >"$COMMAND_OUTPUT" 2>&1
grep -Eq '^kcp process:[[:space:]]+running \(pid\(s\): 4242\)$' "$COMMAND_OUTPUT" \
  || fail "status did not report a running kcp process"
grep -Eq '^Workspace override:[[:space:]]+ignored for read-only status$' "$COMMAND_OUTPUT" \
  || fail "status did not keep the workspace override inert"
grep -Eq '^API readiness:[[:space:]]+ready$' "$COMMAND_OUTPUT" \
  || fail "status did not report a ready guarded API"
grep -Fq 'root:demo' "$COMMAND_OUTPUT" \
  || fail "status did not report the selected workspace from the current server"
grep -Eq '^Demo resources:[[:space:]]+projects=0, shoots=0, seeds=0, cloudprofiles=0$' "$COMMAND_OUTPUT" \
  || fail "status did not report the demo-resource summary"
grep -q '^api|.*<get><--raw=/readyz>' "$KUBECTL_LOG" \
  || fail "status did not use the guarded API readiness request"
while IFS= read -r api_call; do
  [[ "$api_call" == *"|env=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
    || fail "status API call did not receive canonical KUBECONFIG: $api_call"
  [[ "$api_call" == *"|kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
    || fail "status API call did not receive canonical --kubeconfig: $api_call"
  [[ "$api_call" != *"$AMBIENT_KUBECONFIG"* ]] \
    || fail "ambient KUBECONFIG redirected a status API call: $api_call"
done < <(grep '^api|' "$KUBECTL_LOG")
if grep -Eq '^(api|config)\|.*<(ws|apply|create|patch|delete|replace|edit|label|set|use-context)>' "$KUBECTL_LOG"; then
  fail "status issued a mutating or workspace-changing kubectl command"
fi

# Applying the CRD bundle replaces the old fixed sleep with an explicit
# Established wait for every applied definition.
crd_files=("${SCRIPT_DIR}"/crds/*.yaml)
expected_crd_count="${#crd_files[@]}"
crd_names=()
for crd_file in "${crd_files[@]}"; do
  crd_names+=("$(test_yq_read '.metadata.name' "$crd_file")")
done

: >"$KUBECTL_LOG"
run_setup setup-gardener-crds >"$COMMAND_OUTPUT" 2>&1
grep -Fq "<apply><-f><${SCRIPT_DIR}/crds/>" "$KUBECTL_LOG" \
  || fail "setup-gardener-crds did not apply the CRD bundle"
setup_crd_wait_count="$(
  grep -c '^api|.*<wait><--for=condition=Established><--timeout=60s><customresourcedefinition/' "$KUBECTL_LOG"
)"
[[ "$setup_crd_wait_count" -eq "$expected_crd_count" ]] \
  || fail "setup-gardener-crds did not wait for every applied CRD to become Established"
assert_api_calls_use_guarded_kubeconfig "CRD setup"

# A cold ensure discovers every absent CRD before it mutates any CRD. It then
# applies every missing file exactly once before issuing the first Established
# wait, allowing the API server to establish the definitions concurrently.
cp "$ADMIN_KUBECONFIG" "$DASHBOARD_KUBECONFIG"
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy STUB_EXISTING_CRD_NAMES="" \
  run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1
cold_crd_apply_count="$(
  grep -cF "<apply><-f><${SCRIPT_DIR}/crds/" "$KUBECTL_LOG"
)"
[[ "$cold_crd_apply_count" -eq "$expected_crd_count" ]] \
  || fail "cold ensure did not apply every missing CRD exactly once"
cold_crd_wait_count="$(
  grep -c '^api|.*<wait><--for=condition=Established><--timeout=60s><customresourcedefinition/' "$KUBECTL_LOG"
)"
[[ "$cold_crd_wait_count" -eq "$expected_crd_count" ]] \
  || fail "cold ensure did not wait for every missing CRD exactly once"
last_cold_crd_apply_line="$(
  grep -nF "<apply><-f><${SCRIPT_DIR}/crds/" "$KUBECTL_LOG" \
    | tail -n 1 \
    | cut -d: -f1
)"
first_cold_crd_wait_line="$(
  grep -m 1 -n '^api|.*<wait><--for=condition=Established>' "$KUBECTL_LOG" \
    | cut -d: -f1
)"
[[ -n "$last_cold_crd_apply_line" && -n "$first_cold_crd_wait_line" && \
   "$last_cold_crd_apply_line" -lt "$first_cold_crd_wait_line" ]] \
  || fail "cold ensure did not submit every missing CRD before the first Established wait"
assert_api_calls_use_guarded_kubeconfig "cold CRD ensure"

# A healthy repeat still discovers all CRDs but neither applies nor waits for
# definitions that already exist.
all_crd_names="${crd_names[*]}"
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy STUB_EXISTING_CRD_NAMES="$all_crd_names" \
  run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1
existing_crd_get_count="$(
  grep -c '^api|.*<get><customresourcedefinition>' "$KUBECTL_LOG"
)"
[[ "$existing_crd_get_count" -eq "$expected_crd_count" ]] \
  || fail "healthy ensure did not inspect every existing CRD"
if grep -Fq "<apply><-f><${SCRIPT_DIR}/crds/" "$KUBECTL_LOG"; then
  fail "healthy ensure reapplied an existing CRD"
fi
if grep -q '^api|.*<wait><--for=condition=Established>' "$KUBECTL_LOG"; then
  fail "healthy ensure waited for an existing CRD"
fi
assert_api_calls_use_guarded_kubeconfig "healthy CRD ensure"

# A mixed state preserves existing definitions while applying and waiting for
# every missing definition exactly once. All missing applies still precede the
# first wait.
middle_crd_index=$((expected_crd_count / 2))
last_crd_index=$((expected_crd_count - 1))
mixed_existing_crd_names=(
  "${crd_names[0]}"
  "${crd_names[$middle_crd_index]}"
  "${crd_names[$last_crd_index]}"
)
mixed_existing_crds="${mixed_existing_crd_names[*]}"
expected_mixed_missing_count=$((expected_crd_count - ${#mixed_existing_crd_names[@]}))
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy STUB_EXISTING_CRD_NAMES="$mixed_existing_crds" \
  run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1
mixed_crd_apply_count="$(
  grep -cF "<apply><-f><${SCRIPT_DIR}/crds/" "$KUBECTL_LOG"
)"
[[ "$mixed_crd_apply_count" -eq "$expected_mixed_missing_count" ]] \
  || fail "mixed ensure did not apply every missing CRD exactly once"
mixed_crd_wait_count="$(
  grep -c '^api|.*<wait><--for=condition=Established><--timeout=60s><customresourcedefinition/' "$KUBECTL_LOG"
)"
[[ "$mixed_crd_wait_count" -eq "$expected_mixed_missing_count" ]] \
  || fail "mixed ensure did not wait for every missing CRD exactly once"
for crd_index in "${!crd_files[@]}"; do
  crd_file="${crd_files[$crd_index]}"
  crd_name="${crd_names[$crd_index]}"
  crd_apply_count="$(
    grep -cF "<apply><-f><${crd_file}>" "$KUBECTL_LOG" || true
  )"
  crd_wait_count="$(
    grep -cF "<customresourcedefinition/${crd_name}>" "$KUBECTL_LOG" || true
  )"
  case " $mixed_existing_crds " in
    *" $crd_name "*)
      [[ "$crd_apply_count" -eq 0 && "$crd_wait_count" -eq 0 ]] \
        || fail "mixed ensure applied or waited for existing CRD '$crd_name'"
      ;;
    *)
      [[ "$crd_apply_count" -eq 1 && "$crd_wait_count" -eq 1 ]] \
        || fail "mixed ensure did not apply and wait exactly once for missing CRD '$crd_name'"
      ;;
  esac
done
last_mixed_crd_apply_line="$(
  grep -nF "<apply><-f><${SCRIPT_DIR}/crds/" "$KUBECTL_LOG" \
    | tail -n 1 \
    | cut -d: -f1
)"
first_mixed_crd_wait_line="$(
  grep -m 1 -n '^api|.*<wait><--for=condition=Established>' "$KUBECTL_LOG" \
    | cut -d: -f1
)"
[[ -n "$last_mixed_crd_apply_line" && -n "$first_mixed_crd_wait_line" && \
   "$last_mixed_crd_apply_line" -lt "$first_mixed_crd_wait_line" ]] \
  || fail "mixed ensure did not submit every missing CRD before the first Established wait"
assert_api_calls_use_guarded_kubeconfig "mixed CRD ensure"

# An unexpected get failure late in discovery fails closed before any CRD has
# been applied or waited for, including definitions discovered missing earlier.
: >"$KUBECTL_LOG"
if STUB_DEMO_STATE=healthy STUB_EXISTING_CRD_NAMES="" \
    STUB_CRD_GET_FAILURE="${crd_names[$middle_crd_index]}" \
    run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1; then
  fail "CRD ensure continued after an unexpected discovery failure"
fi
grep -Fq "could not inspect customresourcedefinition '${crd_names[$middle_crd_index]}'" "$COMMAND_OUTPUT" \
  || fail "CRD discovery failure did not identify the definition that could not be inspected"
if grep -Fq "<apply><-f><${SCRIPT_DIR}/crds/" "$KUBECTL_LOG"; then
  fail "CRD discovery failure applied a definition before discovery completed"
fi
if grep -q '^api|.*<wait><--for=condition=Established>' "$KUBECTL_LOG"; then
  fail "CRD discovery failure waited for a definition"
fi
assert_api_calls_use_guarded_kubeconfig "failed CRD discovery"

# A missing demo must switch successfully to root before issuing the workspace
# create request. If that root switch fails, creation is refused.
rm -f "$DASHBOARD_KUBECONFIG"
: >"$KUBECTL_LOG"
if STUB_DEMO_STATE=missing STUB_ROOT_SWITCH=unavailable \
    run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1; then
  fail "ensure-single-demo-workspace continued after its root switch failed"
fi
grep -Fq "<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><:root>" "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not explicitly switch to root"
if grep -Fq "<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><create><demo><--enter>" "$KUBECTL_LOG"; then
  fail "ensure-single-demo-workspace created the demo after its root switch failed"
fi

# The legacy multi-workspace fixture has the same fail-closed root requirement.
: >"$KUBECTL_LOG"
if STUB_ROOT_SWITCH=unavailable \
    run_setup create-demo-workspaces >"$COMMAND_OUTPUT" 2>&1; then
  fail "create-demo-workspaces continued after its root switch failed"
fi
if grep -Fq "<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><create><demo-animals><--enter>" "$KUBECTL_LOG"; then
  fail "create-demo-workspaces created a workspace after its root switch failed"
fi

# ensure-single-demo-workspace only creates missing fixture resources. A complete,
# healthy demo is inspected through guarded get calls and receives no resource
# mutation on a repeat run.
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=missing run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1
[[ -f "$DASHBOARD_KUBECONFIG" ]] || fail "ensure-single-demo-workspace did not create the missing dashboard kubeconfig"
grep -q "^api|.*<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><create><demo><--enter>" "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not create a missing demo workspace"
root_switch_line="$(
  grep -nF "<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><:root>" "$KUBECTL_LOG" \
    | head -n 1 \
    | cut -d: -f1
)"
demo_create_line="$(
  grep -nF "<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><create><demo><--enter>" "$KUBECTL_LOG" \
    | head -n 1 \
    | cut -d: -f1
)"
[[ -n "$root_switch_line" && -n "$demo_create_line" && "$root_switch_line" -lt "$demo_create_line" ]] \
  || fail "ensure-single-demo-workspace did not switch to root before creating the demo"
grep -q '^api|.*<create><namespace><garden>' "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not create missing dashboard prerequisites"
grep -q '^api|.*<apply><-f>' "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not apply missing fixture resources"
grep -q '^api|.*<patch><shoot>' "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not initialize a newly created Shoot"
missing_crd_wait_count="$(
  grep -c '^api|.*<wait><--for=condition=Established><--timeout=60s><customresourcedefinition/' "$KUBECTL_LOG"
)"
[[ "$missing_crd_wait_count" -eq "$expected_crd_count" ]] \
  || fail "ensure-single-demo-workspace did not wait for each newly applied CRD"
grep -Fq "<apply><-f><${SCRIPT_DIR}/resources/system-viewer-rbac.yaml>" "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not preserve the upstream system-viewer RBAC"
grep -q '^api|.*<patch><project><garden>' "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not preserve the upstream garden Project"
managed_seed_apply_count="$(
  grep -cF '<apply><-n><garden><-f><->' "$KUBECTL_LOG"
)"
[[ "$managed_seed_apply_count" -ge 12 ]] \
  || fail "ensure-single-demo-workspace did not create the upstream managed seed Shoots and ManagedSeeds"

: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1
grep -Fq 'single demo is ready' "$COMMAND_OUTPUT" \
  || fail "ensure-single-demo-workspace did not report a healthy existing demo"
grep -q '^api|.*<get>' "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not inspect the existing demo"
if grep -Eq '^api\|.*<(apply|create|patch|delete|replace|edit|label|set)>' "$KUBECTL_LOG"; then
  fail "ensure-single-demo-workspace mutated healthy existing demo resources"
fi
if grep -q '^api|.*<wait><--for=condition=Established>' "$KUBECTL_LOG"; then
  fail "ensure-single-demo-workspace waited for CRDs that were already present"
fi

# A generated dashboard kubeconfig that can still reach /readyz but cannot list
# Gardener Projects is unusable and is refreshed from the guarded admin
# configuration without replacing healthy resources.
printf '\nstale-dashboard-credential\n' >>"$DASHBOARD_KUBECONFIG"
: >"$KUBECTL_LOG"
STUB_API_READY=ready STUB_DEMO_STATE=healthy STUB_DASHBOARD_PROJECTS_ACCESS=forbidden \
  run_setup ensure-single-demo-workspace >"$COMMAND_OUTPUT" 2>&1
grep -Fq 'Refreshing the unusable generated dashboard kubeconfig' "$COMMAND_OUTPUT" \
  || fail "ensure-single-demo-workspace did not report refreshing an unusable dashboard kubeconfig"
if grep -Fq 'stale-dashboard-credential' "$DASHBOARD_KUBECONFIG"; then
  fail "ensure-single-demo-workspace did not replace the unusable generated dashboard kubeconfig"
fi
grep -Fq "api|env=${CANONICAL_DASHBOARD_KUBECONFIG}|kubeconfig=${CANONICAL_DASHBOARD_KUBECONFIG}|args=<--kubeconfig=${CANONICAL_DASHBOARD_KUBECONFIG}><--request-timeout=5s><get><projects.core.gardener.cloud><-o><name>" "$KUBECTL_LOG" \
  || fail "ensure-single-demo-workspace did not test the generated dashboard kubeconfig through its guarded Projects probe"
if grep -Fq "kubeconfig=${CANONICAL_DASHBOARD_KUBECONFIG}|args=<--kubeconfig=${CANONICAL_DASHBOARD_KUBECONFIG}><--request-timeout=5s><get><--raw=/readyz>" "$KUBECTL_LOG"; then
  fail "ensure-single-demo-workspace still treated dashboard /readyz as a sufficient capability check"
fi
if grep -Eq '^api\|.*<(apply|create|patch|delete|replace|edit|label|set)>' "$KUBECTL_LOG"; then
  fail "refreshing the generated dashboard kubeconfig mutated healthy fixture resources"
fi

# Named scenarios remain within the guarded local fixture. Their baseline
# inspection uses the canonical kubeconfig, then each state performs only its
# expected fixture mutation.
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy run_setup scenario failing-shoot >"$COMMAND_OUTPUT" 2>&1
grep -Fq "scenario 'failing-shoot' is ready" "$COMMAND_OUTPUT" \
  || fail "failing-shoot scenario did not report success"
grep -q '^api|.*<patch><shoot><pine-oak><-n><garden-pine>' "$KUBECTL_LOG" \
  || fail "failing-shoot scenario did not patch the fixture Shoot"
grep -Fq 'Reconciliation failed in this local fixture.' "$KUBECTL_LOG" \
  || fail "failing-shoot scenario did not apply its failing status fixture"
grep -Fq '<label><shoot><pine-oak><-n><garden-pine><shoot.gardener.cloud/status=unhealthy><--overwrite>' "$KUBECTL_LOG" \
  || fail "failing-shoot scenario did not label the fixture Shoot as unhealthy"
assert_api_calls_use_guarded_kubeconfig "failing-shoot scenario"

: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy run_setup scenario operation-in-progress >"$COMMAND_OUTPUT" 2>&1
grep -Fq "scenario 'operation-in-progress' is ready" "$COMMAND_OUTPUT" \
  || fail "operation-in-progress scenario did not report success"
grep -q '^api|.*<patch><shoot><pine-oak><-n><garden-pine>' "$KUBECTL_LOG" \
  || fail "operation-in-progress scenario did not patch the fixture Shoot"
grep -Fq 'Reconciliation is in progress in this local fixture.' "$KUBECTL_LOG" \
  || fail "operation-in-progress scenario did not apply its progress fixture"
assert_api_calls_use_guarded_kubeconfig "operation-in-progress scenario"

: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy run_setup scenario healthy-shoot >"$COMMAND_OUTPUT" 2>&1
grep -Fq "scenario 'healthy-shoot' is ready" "$COMMAND_OUTPUT" \
  || fail "healthy-shoot scenario did not report success"
grep -q '^api|.*<patch><shoot><pine-oak><-n><garden-pine>' "$KUBECTL_LOG" \
  || fail "healthy-shoot scenario did not patch the fixture Shoot"
grep -Fq 'Shoot cluster has been successfully reconciled.' "$KUBECTL_LOG" \
  || fail "healthy-shoot scenario did not apply its ready status fixture"
grep -Fq 'https://api.pine-oak.pine.shoot.fake.example.com' "$KUBECTL_LOG" \
  || fail "healthy-shoot scenario did not preserve the project-aware advertised address"
assert_api_calls_use_guarded_kubeconfig "healthy-shoot scenario"

# The many-shoots fixture is bounded and creates only missing deterministic
# Shoot names, so rerunning it is safe for the local demo state.
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=missing run_setup scenario many-shoots >"$COMMAND_OUTPUT" 2>&1
grep -Fq "scenario 'many-shoots' is ready" "$COMMAND_OUTPUT" \
  || fail "many-shoots scenario did not report success"
many_shoot_creates="$(grep -c '^api|.*<apply><-n><garden-pine><-f>' "$KUBECTL_LOG")"
[[ "$many_shoot_creates" -ge 14 ]] \
  || fail "many-shoots scenario did not create its bounded Shoot fixture set"
assert_api_calls_use_guarded_kubeconfig "many-shoots scenario"

# A second many-shoots application sees the deterministic fixture names and
# must not create, patch, or replace resources. This represents a safe repeat
# after the first fixture application without contacting a live API.
: >"$KUBECTL_LOG"
STUB_DEMO_STATE=healthy run_setup scenario many-shoots >"$COMMAND_OUTPUT" 2>&1
grep -Fq "scenario 'many-shoots' is ready" "$COMMAND_OUTPUT" \
  || fail "repeated many-shoots scenario did not report success"
grep -q '^api|.*<get>' "$KUBECTL_LOG" \
  || fail "repeated many-shoots scenario did not inspect its deterministic fixture"
if grep -Eq '^api\|.*<(apply|create|patch|delete|replace|edit|label|set)>' "$KUBECTL_LOG"; then
  fail "repeated many-shoots scenario mutated healthy fixture resources"
fi
assert_api_calls_use_guarded_kubeconfig "repeated many-shoots scenario"

: >"$KUBECTL_LOG"
if STUB_DEMO_STATE=healthy run_setup scenario unknown >"$COMMAND_OUTPUT" 2>&1; then
  fail "unknown scenario unexpectedly succeeded"
fi
grep -Fq "unknown scenario 'unknown'" "$COMMAND_OUTPUT" \
  || fail "unknown scenario did not provide actionable choices"
if grep -Eq '^api\|.*<(apply|create|patch|delete|replace|edit|label|set)>' "$KUBECTL_LOG"; then
  fail "unknown scenario mutated the local fixture"
fi

# The repo-local wrapper shares the assertion, forwards non-routing arguments
# exactly, and pins both KUBECONFIG mechanisms to the canonical admin path.
: >"$KUBECTL_LOG"
run_kubectl_gardenerless \
  get shoots -A -l "purpose=visual verification" >"$COMMAND_OUTPUT" 2>&1
wrapper_api_call="$(grep '^api|' "$KUBECTL_LOG")"
[[ "$wrapper_api_call" == *"|env=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
  || fail "kubectl-gardenerless did not set canonical KUBECONFIG"
[[ "$wrapper_api_call" == *"|kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
  || fail "kubectl-gardenerless did not pass canonical --kubeconfig"
[[ "$wrapper_api_call" == *'<get><shoots><-A><-l><purpose=visual verification>'* ]] \
  || fail "kubectl-gardenerless changed forwarded argument boundaries"
[[ "$wrapper_api_call" != *"$AMBIENT_KUBECONFIG"* ]] \
  || fail "ambient KUBECONFIG redirected kubectl-gardenerless"

: >"$KUBECTL_LOG"
run_kubectl_gardenerless ws :root >"$COMMAND_OUTPUT" 2>&1
wrapper_plugin_call="$(grep '^api|' "$KUBECTL_LOG")"
[[ "$wrapper_plugin_call" == *"|env=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
  || fail "kubectl-gardenerless plugin call did not set canonical KUBECONFIG"
[[ "$wrapper_plugin_call" == *"|kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}|"* ]] \
  || fail "kubectl-gardenerless plugin call did not pass canonical --kubeconfig"
[[ "$wrapper_plugin_call" == *"<ws><--kubeconfig=${CANONICAL_ADMIN_KUBECONFIG}><:root>"* ]] \
  || fail "kubectl-gardenerless did not place --kubeconfig after the plugin name"
[[ "$wrapper_plugin_call" != *"$AMBIENT_KUBECONFIG"* ]] \
  || fail "ambient KUBECONFIG redirected kubectl-gardenerless plugin call"

first_wrapper_api_line="$(grep -n '^api|' "$KUBECTL_LOG" | head -n 1 | cut -d: -f1)"
wrapper_config_calls_before_api="$(
  sed -n "1,$((first_wrapper_api_line - 1))p" "$KUBECTL_LOG" | grep -c '^config|'
)"
[[ "$wrapper_config_calls_before_api" -ge 6 ]] \
  || fail "kubectl-gardenerless reached the API before validation completed"

# Rejected or missing admin configurations cause zero wrapper API calls.
: >"$KUBECTL_LOG"
if STUB_SERVER_OVERRIDE="$REJECTED_SERVER" \
    run_kubectl_gardenerless get shoots -A >"$COMMAND_OUTPUT" 2>&1; then
  fail "kubectl-gardenerless accepted a non-loopback kubeconfig"
fi
assert_no_api_calls "kubectl-gardenerless reached the API with a rejected kubeconfig"

mv "$ADMIN_KUBECONFIG" "${ADMIN_KUBECONFIG}.saved"
: >"$KUBECTL_LOG"
if run_kubectl_gardenerless get shoots -A >"$COMMAND_OUTPUT" 2>&1; then
  fail "kubectl-gardenerless accepted a missing admin kubeconfig"
fi
assert_no_api_calls "kubectl-gardenerless reached the API without an admin kubeconfig"
mv "${ADMIN_KUBECONFIG}.saved" "$ADMIN_KUBECONFIG"

# Callers cannot override the asserted cluster, context, or TLS route.
assert_wrapper_override_rejected get shoots --kubeconfig "$AMBIENT_KUBECONFIG"
assert_wrapper_override_rejected get shoots "--server=$REJECTED_SERVER"
assert_wrapper_override_rejected get shoots --context remote
assert_wrapper_override_rejected get shoots --cluster remote
assert_wrapper_override_rejected get shoots --certificate-authority "$RUNTIME_CERT"
assert_wrapper_override_rejected get shoots --insecure-skip-tls-verify=true
assert_wrapper_override_rejected get shoots --tls-server-name api.example.invalid
assert_wrapper_override_rejected get shoots --proxy-url http://api.example.invalid

printf 'PASS: gardenerless script and repo-local kubectl guard fixtures\n'
