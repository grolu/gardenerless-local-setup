#!/bin/bash
set -o pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# logging helpers (keep using echo -e for ANSI colors)
log_info()  { echo -e "$*";                  }
log_error() { echo -e "$*" >&2;              }

# timestamp helper
now()       { date -u +%Y-%m-%dT%H:%M:%SZ;    }

RES_DIR="${SCRIPT_DIR}/resources"
KCP_PROVENANCE_FILE="${SCRIPT_DIR}/kcp-version.env"
# shellcheck source=kcp-version.env
if ! source "$KCP_PROVENANCE_FILE"; then
  log_error "Error: could not load kcp provenance from '$KCP_PROVENANCE_FILE'."
  exit 1
fi
if [[ ! "$KCP_RELEASE" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
   [[ ! "$KCP_COMMIT" =~ ^[0-9a-f]{40}$ ]] || \
   [[ -z "$KCP_REPO" ]]; then
  log_error "Error: invalid kcp provenance in '$KCP_PROVENANCE_FILE'."
  exit 1
fi
KCP_DIR="${GARDENERLESS_KCP_DIR:-${SCRIPT_DIR}/kcp}"
KCP_STATE_DIR="${KCP_DIR}/.kcp"
KCP_BIN_DIR="${KCP_DIR}/bin"
KCP_BINARY="${KCP_BIN_DIR}/kcp"
KCP_KUBECTL_KCP_BINARY="${KCP_BIN_DIR}/kubectl-kcp"
KCP_KUBECTL_WS_BINARY="${KCP_BIN_DIR}/kubectl-ws"
KCP_KUBECONFIG="${KCP_STATE_DIR}/admin.kubeconfig"
dashboard_kcp_cfg="${KCP_STATE_DIR}/dashboard-kcp.kubeconfig"
dashboard_single_cfg="${KCP_STATE_DIR}/dashboard.kubeconfig"
ACTIVE_GARDENERLESS_KUBECONFIG=""

# quiet / silent wrappers
run_quiet()  { "$@" >/dev/null; }
run_silent() { "$@" >/dev/null 2>&1; }

# yq wrappers also allows ubuntu yq to work
# Return 0 if this is mikefarah/yq (Go), else 1 (kislyuk/yq wrapper)
is_mikefarah_yq() {
  yq --version 2>/dev/null | grep -qiE 'mikefarah|version v?[0-9]+\.'  # v4 prints like "yq (https://github.com/mikefarah/yq/) version v4.x.x"
}

# yq expression file  -> prints value
yq_read() {
  local expr=$1
  local file=$2
  if is_mikefarah_yq; then
    yq e "$expr" "$file"
  else
    # kislyuk/yq -> jq underneath; -r = raw string (no quotes)
    yq -r "$expr" "$file"
  fi
}

# stdin yaml -> stdout json
yq_to_json() {
  if is_mikefarah_yq; then
    yq -o=json
  else
    yq -c '.'
  fi
}

# shellcheck source=lib/gardenerless-kubeconfig.sh
source "${SCRIPT_DIR}/lib/gardenerless-kubeconfig.sh"

activate_gardenerless_kubeconfig() {
  if ! cache_guarded_kubeconfig "$1"; then
    return 1
  fi

  ACTIVE_GARDENERLESS_KUBECONFIG="$GUARDED_KUBECTL_CANONICAL_KUBECONFIG"
}

active_kubectl() {
  if [[ -z "$ACTIVE_GARDENERLESS_KUBECONFIG" ]]; then
    log_error "Error: refusing kubectl invocation before a gardenerless kubeconfig has passed validation."
    return 1
  fi

  guarded_kubectl "$ACTIVE_GARDENERLESS_KUBECONFIG" "$@"
}

init_kubeconfig() {
  activate_gardenerless_kubeconfig "$KCP_KUBECONFIG"
}

switch_to_root() {
  run_quiet active_kubectl config use-context root || return 1
  run_quiet active_kubectl ws :root
}

apply_yaml_template() {
  sed -e "s/NAMESPACEPLACEHOLDER/$3/g" \
      -e "s/NAMEPLACEHOLDER/$2/g" "$1"
}

create_kubeconfig() {
  local dest="$1" ws="$2"
  local previous_kubeconfig="$ACTIVE_GARDENERLESS_KUBECONFIG"
  local cur

  log_info "${YELLOW}Creating kubeconfig for workspace '$ws'...${NC}"
  if ! cp "$KCP_KUBECONFIG" "$dest"; then
    return 1
  fi
  if ! activate_gardenerless_kubeconfig "$dest"; then
    ACTIVE_GARDENERLESS_KUBECONFIG="$previous_kubeconfig"
    return 1
  fi

  run_quiet active_kubectl config use-context root
  run_quiet active_kubectl ws :root
  if [[ "$ws" != "base" ]]; then
    run_quiet active_kubectl ws ":root:$ws"
  fi
  if ! run_silent active_kubectl config use-context "$ws"; then
    cur=$(active_kubectl config current-context)
    run_quiet active_kubectl config rename-context "$cur" "$ws"
    run_quiet active_kubectl config use-context "$ws"
  fi

  ACTIVE_GARDENERLESS_KUBECONFIG="$previous_kubeconfig"
}

dashboard_kubeconfig_is_usable() {
  local previous_kubeconfig="$ACTIVE_GARDENERLESS_KUBECONFIG"
  local result=0

  if ! activate_gardenerless_kubeconfig "$dashboard_single_cfg"; then
    result=1
  elif ! run_silent active_kubectl --request-timeout=5s \
      get projects.core.gardener.cloud -o name; then
    result=1
  fi

  ACTIVE_GARDENERLESS_KUBECONFIG="$previous_kubeconfig"
  return "$result"
}

wait_for_crd_established() {
  local crd_name="$1"

  run_quiet active_kubectl wait \
    --for=condition=Established \
    --timeout=60s \
    "customresourcedefinition/${crd_name}"
}

setup_gardener_crds() {
  local file crd_name

  log_info "${YELLOW}Setting up Gardener CRDs...${NC}"
  run_quiet active_kubectl apply -f "${SCRIPT_DIR}/crds/" || return 1
  for file in "${SCRIPT_DIR}"/crds/*.yaml; do
    if ! crd_name=$(yq_read '.metadata.name' "$file"); then
      log_error "Error: could not read the CRD name from '$file'."
      return 1
    fi
    wait_for_crd_established "$crd_name" || return 1
  done
  log_info "${GREEN}Gardener CRDs are established.${NC}"
}

apply_cluster_resources() {
  log_info "${YELLOW}Applying cluster resources...${NC}"
  run_quiet active_kubectl apply -f "$RES_DIR/cloudprofile-*.yaml"
  run_quiet active_kubectl apply -f "$RES_DIR/seed-*.yaml"
  for f in "$RES_DIR"/seed-*.yaml; do
    name=$(yq_read '.metadata.name' "$f")
    patch_seed_status "$name"
    # Create managed seed for all seeds except soil
    if [[ "$name" != "soil" ]]; then
      create_managed_seed "$f"
    fi
  done
}

create_project_resource() {
  log_info "${YELLOW}Creating project resource '$1'...${NC}"
  apply_yaml_template "$RES_DIR/project-template.yaml" "$1" "$2" \
    | run_quiet active_kubectl apply -f -
}

patch_project_status() {
  log_info "${YELLOW}Marking project '$1' as Ready...${NC}"
  run_quiet active_kubectl patch project "$1" \
    --type=merge --subresource=status -p '{"status":{"phase":"Ready"}}'
}

patch_shoot_ready() {
  patch_shoot_status_from_template "$1" "$2" "${RES_DIR}/status-shoot-ready.yaml"
}

patch_shoot_status_from_template() {
  local shoot="$1" ns="$2" template="$3"
  local project="${ns#garden-}"
  local now
  now="$(now)"
  local patch_yaml
  patch_yaml=$(apply_yaml_template "$template" "$shoot" "$ns" \
    | sed -e "s/DATEPLACEHOLDER/${now}/g" -e "s/PROJECTPLACEHOLDER/${project}/g")
  local json_patch
  json_patch=$(printf '%s' "$patch_yaml" | yq_to_json)
  run_quiet active_kubectl patch shoot "$shoot" -n "$ns" --type=merge --subresource=status -p "$json_patch"

  if [[ "$template" == "${RES_DIR}/status-shoot-ready.yaml" ]]; then
    run_quiet active_kubectl label shoot "$shoot" -n "$ns" shoot.gardener.cloud/status="healthy" --overwrite
  elif [[ "$template" == "${RES_DIR}/status-shoot-failing.yaml" ]]; then
    run_quiet active_kubectl label shoot "$shoot" -n "$ns" shoot.gardener.cloud/status="unhealthy" --overwrite
  fi
}

patch_seed_status() {
  local seed="$1"
  local now
  now="$(now)"
  local patch_yaml
  patch_yaml=$(sed -e "s/DATEPLACEHOLDER/${now}/g" "$RES_DIR/status-seed.yaml")
  local json_patch
  json_patch=$(printf '%s' "$patch_yaml" | yq_to_json)
  run_quiet active_kubectl patch seed "$seed" --type=merge --subresource=status -p "$json_patch"
}

patch_shoot_seed_status() {
  local shoot="$1"
  local now
  now="$(now)"
  local patch_yaml
  patch_yaml=$(sed -e "s/NAMEPLACEHOLDER/${shoot}/g" -e "s/DATEPLACEHOLDER/${now}/g" "$RES_DIR/status-shoot-seed.yaml")
  local json_patch
  json_patch=$(printf '%s' "$patch_yaml" | yq_to_json)
  run_quiet active_kubectl patch shoot "$shoot" -n garden --type=merge --subresource=status -p "$json_patch"
  run_quiet active_kubectl label shoot "$shoot" -n garden shoot.gardener.cloud/status="healthy" --overwrite
}

create_managed_seed() {
  local seed_file="$1"
  local seed_name
  seed_name=$(yq_read '.metadata.name' "$seed_file")
  local provider
  provider=$(yq_read '.spec.provider.type' "$seed_file")
  local region
  region=$(yq_read '.spec.provider.region' "$seed_file")
  local zone
  zone=$(yq_read '.spec.provider.zones[0]' "$seed_file")

  log_info "${YELLOW}Creating managed seed shoot for '$seed_name'...${NC}"

  # Create seed shoot
  sed -e "s/NAMEPLACEHOLDER/${seed_name}/g" \
      -e "s/CLOUDPROFILEPLACEHOLDER/${provider}/g" \
      -e "s/PROVIDERPLACEHOLDER/${provider}/g" \
      -e "s/REGIONPLACEHOLDER/${region}/g" \
      -e "s/ZONEPLACEHOLDER/${zone}/g" \
      -e "s/SEEDPLACEHOLDER/soil/g" \
      "$RES_DIR/shoot-seed-template.yaml" | run_quiet active_kubectl apply -n garden -f -

  # Patch seed shoot status
  patch_shoot_seed_status "$seed_name"

  # Create ManagedSeed resource
  log_info "${YELLOW}Creating ManagedSeed resource for '$seed_name'...${NC}"
  sed -e "s/NAMEPLACEHOLDER/${seed_name}/g" \
      "$RES_DIR/managedseed-template.yaml" | run_quiet active_kubectl apply -n garden -f -
}

KCP_VERIFY_ERROR=""
KCP_VERIFY_STATUS="unavailable"
KCP_VERIFIED_COMMIT=""

kcp_verification_failed() {
  KCP_VERIFY_ERROR="$1"
  return 1
}

# Keep verification reads from refreshing Git's index or invoking a configured
# filesystem monitor. This path must remain safe for automation to call.
kcp_git_read() {
  GIT_OPTIONAL_LOCKS=0 git \
    -c core.fsmonitor=false \
    -c core.untrackedCache=false \
    -C "$KCP_DIR" \
    "$@"
}

verify_kcp_worktree_root() {
  local selected_root worktree_root inside_worktree

  if [[ ! -d "$KCP_DIR" ]]; then
    kcp_verification_failed "selected kcp runtime directory '$KCP_DIR' does not exist"
    return
  fi
  if ! selected_root=$(cd -- "$KCP_DIR" 2>/dev/null && pwd -P); then
    kcp_verification_failed "could not resolve selected kcp runtime directory '$KCP_DIR'"
    return
  fi
  if ! inside_worktree=$(kcp_git_read rev-parse --is-inside-work-tree 2>/dev/null) || \
     [[ "$inside_worktree" != "true" ]]; then
    kcp_verification_failed "selected kcp runtime '$KCP_DIR' is not a Git worktree"
    return
  fi
  if ! worktree_root=$(kcp_git_read rev-parse --show-toplevel 2>/dev/null) || \
     ! worktree_root=$(cd -- "$worktree_root" 2>/dev/null && pwd -P); then
    kcp_verification_failed "could not determine the Git worktree root for '$KCP_DIR'"
    return
  fi
  if [[ "$worktree_root" != "$selected_root" ]]; then
    kcp_verification_failed "selected kcp runtime '$selected_root' is not the Git worktree root '$worktree_root'"
    return
  fi
}

verify_kcp_checkout() {
  local checkout_commit checkout_state checkout_line symbolic_ref_status

  KCP_VERIFIED_COMMIT=""
  KCP_VERIFY_STATUS="unavailable"
  verify_kcp_worktree_root || return 1

  if ! checkout_commit=$(kcp_git_read rev-parse --verify HEAD 2>/dev/null); then
    kcp_verification_failed "could not resolve HEAD in kcp runtime '$KCP_DIR'"
    return
  fi
  KCP_VERIFY_STATUS="mismatch"
  if [[ ! "$checkout_commit" =~ ^[0-9a-f]{40}$ ]]; then
    kcp_verification_failed "kcp checkout HEAD '$checkout_commit' is not a 40-character lowercase commit"
    return
  fi
  if [[ "$checkout_commit" != "$KCP_COMMIT" ]]; then
    kcp_verification_failed "kcp checkout HEAD is ${checkout_commit}, expected ${KCP_COMMIT}; run setup-kcp"
    return
  fi

  kcp_git_read symbolic-ref -q HEAD >/dev/null 2>&1
  symbolic_ref_status=$?
  if [[ $symbolic_ref_status -eq 0 ]]; then
    kcp_verification_failed "kcp checkout is attached to a branch; run setup-kcp to restore detached HEAD ${KCP_COMMIT}"
    return
  fi
  if [[ $symbolic_ref_status -ne 1 ]]; then
    kcp_verification_failed "could not determine whether the kcp checkout uses detached HEAD"
    return
  fi

  if ! checkout_state=$(kcp_git_read status \
      --porcelain=v1 \
      --untracked-files=all \
      --ignored=matching \
      --ignore-submodules=none \
      --no-ahead-behind 2>/dev/null); then
    kcp_verification_failed "could not inspect kcp checkout drift"
    return
  fi
  while IFS= read -r checkout_line; do
    [[ -z "$checkout_line" ]] && continue
    case "$checkout_line" in
      "!! .kcp/"|"!! bin/"*) ;;
      *)
        kcp_verification_failed "unexpected kcp checkout drift: ${checkout_line}; run setup-kcp"
        return
        ;;
    esac
  done <<<"$checkout_state"

  KCP_VERIFIED_COMMIT="$checkout_commit"
  KCP_VERIFY_STATUS="verified"
}

verify_kcp_binary() {
  local build_info build_line embedded_revision="" revision_count=0

  if [[ -L "$KCP_BINARY" ]]; then
    kcp_verification_failed "kcp binary '$KCP_BINARY' must not be a symbolic link; run setup-kcp"
    return
  fi
  if [[ ! -f "$KCP_BINARY" ]]; then
    kcp_verification_failed "kcp binary '$KCP_BINARY' is missing or not a regular file; run setup-kcp"
    return
  fi
  if [[ ! -x "$KCP_BINARY" ]]; then
    kcp_verification_failed "kcp binary '$KCP_BINARY' is not executable; run setup-kcp"
    return
  fi
  if ! command -v go >/dev/null 2>&1; then
    kcp_verification_failed "go is required to inspect '$KCP_BINARY' with 'go version -m'"
    return
  fi
  if ! build_info=$(go version -m "$KCP_BINARY" 2>&1); then
    kcp_verification_failed "could not read Go build metadata from '$KCP_BINARY'; run setup-kcp"
    return
  fi

  while IFS= read -r build_line; do
    case "$build_line" in
      $'\tbuild\tvcs.revision='*)
        embedded_revision="${build_line#$'\tbuild\tvcs.revision='}"
        ((revision_count += 1))
        ;;
    esac
  done <<<"$build_info"
  if [[ $revision_count -ne 1 ]]; then
    kcp_verification_failed "kcp binary must contain exactly one vcs.revision, found ${revision_count}; run setup-kcp"
    return
  fi
  if [[ ! "$embedded_revision" =~ ^[0-9a-f]{40}$ ]]; then
    kcp_verification_failed "kcp binary vcs.revision '$embedded_revision' is not a 40-character lowercase commit; run setup-kcp"
    return
  fi
  if [[ "$embedded_revision" != "$KCP_COMMIT" ]]; then
    kcp_verification_failed "kcp binary vcs.revision is ${embedded_revision}, expected ${KCP_COMMIT}; run setup-kcp"
    return
  fi
}

verify_kcp_runtime() {
  KCP_VERIFY_ERROR=""
  verify_kcp_checkout && verify_kcp_binary
}

verify_kcp_json() {
  if ! verify_kcp_runtime; then
    log_error "Error: kcp runtime verification failed: ${KCP_VERIFY_ERROR}."
    return 1
  fi

  printf '{"schemaVersion":1,"release":"%s","commit":"%s"}\n' \
    "$KCP_RELEASE" "$KCP_VERIFIED_COMMIT"
}

setup_kcp() {
  local tag_ref="refs/tags/${KCP_RELEASE}"
  local origin_url tag_commit checkout_commit
  local binary

  if ! mkdir -p "$KCP_DIR"; then
    log_error "Error: could not create the kcp runtime directory '$KCP_DIR'."
    return 1
  fi

  if ! run_silent git -C "$KCP_DIR" rev-parse --git-dir; then
    log_info "${YELLOW}Initializing the repository-local kcp checkout...${NC}"
    run_quiet git -C "$KCP_DIR" init || return 1
  fi
  if ! verify_kcp_worktree_root; then
    log_error "Error: refusing unsafe kcp checkout: ${KCP_VERIFY_ERROR}."
    return 1
  fi

  if origin_url=$(git -C "$KCP_DIR" remote get-url origin 2>/dev/null); then
    if [[ "$origin_url" != "$KCP_REPO" ]]; then
      log_info "${YELLOW}Restoring the repository-owned kcp origin...${NC}"
      run_quiet git -C "$KCP_DIR" remote set-url origin "$KCP_REPO" || return 1
    fi
  else
    run_quiet git -C "$KCP_DIR" remote add origin "$KCP_REPO" || return 1
  fi

  log_info "${YELLOW}Fetching kcp ${KCP_RELEASE}...${NC}"
  run_quiet git -C "$KCP_DIR" fetch \
    --force \
    --depth=1 \
    --no-tags \
    origin \
    "${tag_ref}:${tag_ref}" || return 1

  if ! tag_commit=$(git -C "$KCP_DIR" rev-parse --verify "${tag_ref}^{commit}"); then
    log_error "Error: kcp tag ${KCP_RELEASE} does not resolve to a commit."
    return 1
  fi
  if [[ "$tag_commit" != "$KCP_COMMIT" ]]; then
    log_error "Error: kcp tag ${KCP_RELEASE} resolves to commit ${tag_commit}, expected ${KCP_COMMIT}."
    return 1
  fi

  log_info "${YELLOW}Checking out verified kcp commit ${KCP_COMMIT}...${NC}"
  run_quiet git -C "$KCP_DIR" checkout --detach --force "$KCP_COMMIT" || return 1
  run_quiet git -C "$KCP_DIR" clean -ffdx -e .kcp/ || return 1

  if ! checkout_commit=$(git -C "$KCP_DIR" rev-parse --verify HEAD); then
    log_error "Error: could not verify the checked-out kcp commit."
    return 1
  fi
  if [[ "$checkout_commit" != "$KCP_COMMIT" ]]; then
    log_error "Error: checked-out kcp commit is ${checkout_commit}, expected ${KCP_COMMIT}."
    return 1
  fi
  if ! verify_kcp_checkout; then
    log_error "Error: checked-out kcp source failed verification: ${KCP_VERIFY_ERROR}."
    return 1
  fi

  log_info "${YELLOW}Building repository-local kcp binaries...${NC}"
  run_quiet make -C "$KCP_DIR" build || return 1
  for binary in kcp kubectl-kcp kubectl-ws; do
    if [[ ! -x "${KCP_BIN_DIR}/${binary}" ]]; then
      log_error "Error: kcp build did not produce executable '${KCP_BIN_DIR}/${binary}'."
      return 1
    fi
  done
  if ! verify_kcp_runtime; then
    log_error "Error: built kcp runtime failed verification: ${KCP_VERIFY_ERROR}."
    return 1
  fi
  log_info "${GREEN}kcp ${KCP_RELEASE} binaries are available in ${KCP_BIN_DIR}.${NC}"
}

start_kcp_server() {
  if pgrep -f "$KCP_BINARY"; then
    log_info "${GREEN}kcp server already running.${NC}"
    exit 0
  fi
  cd "$KCP_DIR" || return 1
  exec "$KCP_BINARY" start --bind-address=127.0.0.1
}

get_shoots() {
  case "$1:$2" in
    demo-animals:cat)        echo "cat-alpha cat"      ;;
    demo-animals:dog)        echo "dog-alpha dog"      ;;
    demo-plants:pine)        echo "pine-oak pine"      ;;
    demo-plants:rose)        echo "rose-blossom rose"  ;;
    demo-plants:sunflower)   echo "sunflower-sunny sunflower" ;;
    demo-cars:bmw)           echo "bmw-m3 bmw-x5 bmw"  ;;
    demo-cars:mercedes)      echo "merc-c300 merc-e350 merc" ;;
    demo-cars:tesla)         echo "tesla-model3 tesla-models tesla" ;;
    demo:pine)               echo "pine-oak pine"      ;;
    demo:rose)               echo "rose-blossom rose"  ;;
    demo:sunflower)          echo "sunflower-sunny sunflower" ;;
  esac
}

# toggles a single shoot between ready and error

# every $interval seconds, pick a random shoot (optionally per project) and flip it

# simulate a long-running operation (Processing→Succeeded)

create_shoot () {
    local name=$1 ns=$2
    log_info "${YELLOW}Creating shoot resource '$name' in namespace '$ns'...${NC}"
    apply_yaml_template "${RES_DIR}/shoot-template.yaml" "$name" "$ns" | active_kubectl apply -n "$ns" -f - >/dev/null
    patch_shoot_ready "$name" "$ns"
}


generate_uid() {
    tr -dc a-z0-9 </dev/urandom | head -c10
}

bulk_projects() {
    local count=$1
    echo -e "${YELLOW}Bulk-creating $count project(s)...${NC}"
    for ((i=1;i<=count;i++)); do
        name=$(generate_uid)
        NAMESPACE="garden-$name"
        run_silent active_kubectl get ns "$NAMESPACE" || run_quiet active_kubectl create ns "$NAMESPACE"
        create_project_resource "$name" "$NAMESPACE"
        patch_project_status "$name"
    done
}

bulk_shoots() {
    local proj=$1 count=$2
    local ns="garden-$proj"
    if ! run_silent active_kubectl get ns "$ns"; then
        echo -e "${RED}project ns $ns not found${NC}"
        exit 1
    fi
    echo -e "${YELLOW}Creating $count shoot(s) in project '$proj'...${NC}"
    for ((i=1;i<=count;i++)); do
        sname=$(generate_uid)
        create_shoot "$sname" "$ns"
    done
}

create_demo_ws() {
    local ws=$1
    echo -e "${YELLOW}Creating demo workspace $ws...${NC}"
    if ! switch_to_root; then
      log_error "Error: could not switch to root before creating demo workspace '$ws'."
      return 1
    fi
    if ! run_silent active_kubectl ws create "$ws" --enter && \
       ! run_quiet active_kubectl ws "$ws"; then
      log_error "Error: could not create or enter demo workspace '$ws'."
      return 1
    fi
    echo -e "${YELLOW}Setting up dashboard-user service account...${NC}"
    run_quiet active_kubectl create ns garden
    run_quiet active_kubectl create sa dashboard-user -n garden
    run_quiet active_kubectl create clusterrolebinding cluster-admin --clusterrole=cluster-admin --serviceaccount=garden:dashboard-user
    run_quiet active_kubectl set subject clusterrolebinding cluster-admin --serviceaccount=garden:dashboard-user
    run_quiet active_kubectl apply -f "$RES_DIR/system-viewer-rbac.yaml"
    setup_gardener_crds
    apply_cluster_resources
    create_project_resource "garden" "garden"
    patch_project_status "garden"
    case "$ws" in
        demo-animals) projects="cat dog" ;;
        demo-plants)  projects="pine rose sunflower" ;;
        demo)         projects="pine rose sunflower" ;;
        demo-cars)    projects="bmw mercedes tesla" ;;
    esac
    for proj in $projects; do
        ns="garden-${proj}"
        run_silent active_kubectl get ns "$ns" || run_quiet active_kubectl create ns "$ns"
        create_project_resource "$proj" "$ns"
        patch_project_status "$proj"
        for shoot in $(get_shoots "$ws" "$proj"); do
            create_shoot "$shoot" "$ns"
        done
        apply_yaml_template "${RES_DIR}/secret-template.yaml" "aws-secret" "$ns" | active_kubectl apply -n "$ns" -f - >/dev/null
        apply_yaml_template "${RES_DIR}/secretbinding-template.yaml" "aws-secret-binding" "$ns" | active_kubectl apply -n "$ns" -f - >/dev/null
    done
}

# Return success only when a named resource is present. --ignore-not-found
# distinguishes a genuinely absent fixture resource from an API or permission
# failure, which must not be treated as permission to create something.
resource_exists() {
  local resource="$1" name="$2" existing
  shift 2

  if ! existing=$(active_kubectl get "$resource" "$name" "$@" --ignore-not-found -o name 2>/dev/null); then
    log_error "Error: could not inspect $resource '$name'; refusing to change the demo."
    return 2
  fi

  [[ -n "$existing" ]]
}

ensure_resource_from_file() {
  local resource="$1" file="$2" name resource_status

  if ! name=$(yq_read '.metadata.name' "$file"); then
    log_error "Error: could not read the resource name from '$file'."
    return 1
  fi

  resource_exists "$resource" "$name"
  resource_status=$?
  if [[ $resource_status -eq 0 ]]; then
    return 0
  fi
  [[ $resource_status -eq 1 ]] || return "$resource_status"

  active_kubectl apply -f "$file" >/dev/null
}

ensure_templated_resource() {
  local resource="$1" template="$2" name="$3" namespace="$4" resource_status

  resource_exists "$resource" "$name" -n "$namespace"
  resource_status=$?
  if [[ $resource_status -eq 0 ]]; then
    return 0
  fi
  [[ $resource_status -eq 1 ]] || return "$resource_status"

  apply_yaml_template "$template" "$name" "$namespace" \
    | active_kubectl apply -n "$namespace" -f - >/dev/null
}

ensure_system_viewer_rbac() {
  local resource_status
  local needs_apply=0

  resource_exists clusterrole gardener.cloud:system:viewers
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    needs_apply=1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi

  resource_exists serviceaccount landscape-viewer -n garden
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    needs_apply=1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi

  resource_exists clusterrolebinding gardener.cloud:system:viewers:landscape-viewer
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    needs_apply=1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi

  if [[ $needs_apply -eq 1 ]]; then
    active_kubectl apply -f "$RES_DIR/system-viewer-rbac.yaml" >/dev/null
  fi
}

ensure_gardener_crds() {
  local file crd_name resource_status
  local -a missing_crd_files=()
  local -a missing_crd_names=()

  for file in "${SCRIPT_DIR}"/crds/*.yaml; do
    if ! crd_name=$(yq_read '.metadata.name' "$file"); then
      log_error "Error: could not read the CRD name from '$file'."
      return 1
    fi
    resource_exists customresourcedefinition "$crd_name"
    resource_status=$?
    if [[ $resource_status -eq 0 ]]; then
      continue
    fi
    [[ $resource_status -eq 1 ]] || return "$resource_status"

    missing_crd_files+=("$file")
    missing_crd_names+=("$crd_name")
  done

  for file in "${missing_crd_files[@]}"; do
    active_kubectl apply -f "$file" >/dev/null || return 1
  done

  for crd_name in "${missing_crd_names[@]}"; do
    wait_for_crd_established "$crd_name" || return 1
  done
}

ensure_managed_seed() {
  local seed_file="$1"
  local seed_name provider region zone resource_status

  if ! seed_name=$(yq_read '.metadata.name' "$seed_file") || \
     ! provider=$(yq_read '.spec.provider.type' "$seed_file") || \
     ! region=$(yq_read '.spec.provider.region' "$seed_file") || \
     ! zone=$(yq_read '.spec.provider.zones[0]' "$seed_file"); then
    log_error "Error: could not read ManagedSeed inputs from '$seed_file'."
    return 1
  fi

  resource_exists shoot "$seed_name" -n garden
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    log_info "${YELLOW}Creating missing managed seed shoot '$seed_name'...${NC}"
    sed -e "s/NAMEPLACEHOLDER/${seed_name}/g" \
        -e "s/CLOUDPROFILEPLACEHOLDER/${provider}/g" \
        -e "s/PROVIDERPLACEHOLDER/${provider}/g" \
        -e "s/REGIONPLACEHOLDER/${region}/g" \
        -e "s/ZONEPLACEHOLDER/${zone}/g" \
        -e "s/SEEDPLACEHOLDER/soil/g" \
        "$RES_DIR/shoot-seed-template.yaml" \
      | active_kubectl apply -n garden -f - >/dev/null || return 1
    patch_shoot_seed_status "$seed_name" || return 1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi

  resource_exists managedseed "$seed_name" -n garden
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    log_info "${YELLOW}Creating missing ManagedSeed resource '$seed_name'...${NC}"
    sed -e "s/NAMEPLACEHOLDER/${seed_name}/g" \
        "$RES_DIR/managedseed-template.yaml" \
      | active_kubectl apply -n garden -f - >/dev/null
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi
}

ensure_cluster_resources() {
  local file seed_name resource_status

  for file in "$RES_DIR"/cloudprofile-*.yaml; do
    ensure_resource_from_file cloudprofile "$file" || return 1
  done
  for file in "$RES_DIR"/seed-*.yaml; do
    if ! seed_name=$(yq_read '.metadata.name' "$file"); then
      log_error "Error: could not read the Seed name from '$file'."
      return 1
    fi
    resource_exists seed "$seed_name"
    resource_status=$?
    if [[ $resource_status -eq 1 ]]; then
      active_kubectl apply -f "$file" >/dev/null || return 1
      patch_seed_status "$seed_name" || return 1
    elif [[ $resource_status -ne 0 ]]; then
      return "$resource_status"
    fi

    if [[ "$seed_name" != "soil" ]]; then
      ensure_managed_seed "$file" || return 1
    fi
  done
}

ensure_demo_workspace() {
  local workspace="$1"

  if run_silent active_kubectl ws ":root:${workspace}"; then
    return 0
  fi

  if ! switch_to_root; then
    log_error "Error: could not switch to root before creating demo workspace '$workspace'."
    return 1
  fi
  log_info "${YELLOW}Creating missing demo workspace '$workspace'...${NC}"
  active_kubectl ws create "$workspace" --enter >/dev/null
}

ensure_single_demo() {
  local workspace="demo" namespace project shoot resource_status

  log_info "${YELLOW}Ensuring the single demo without replacing existing resources...${NC}"
  ensure_demo_workspace "$workspace" || return 1

  resource_exists namespace garden
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    active_kubectl create namespace garden >/dev/null || return 1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi
  resource_exists serviceaccount dashboard-user -n garden
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    active_kubectl create serviceaccount dashboard-user -n garden >/dev/null || return 1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi
  resource_exists clusterrolebinding cluster-admin
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    active_kubectl create clusterrolebinding cluster-admin \
      --clusterrole=cluster-admin --serviceaccount=garden:dashboard-user >/dev/null || return 1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi
  ensure_system_viewer_rbac || return 1

  ensure_gardener_crds || return 1
  ensure_cluster_resources || return 1

  resource_exists project garden
  resource_status=$?
  if [[ $resource_status -eq 1 ]]; then
    create_project_resource garden garden || return 1
    patch_project_status garden || return 1
  elif [[ $resource_status -ne 0 ]]; then
    return "$resource_status"
  fi

  for project in pine rose sunflower; do
    namespace="garden-${project}"
    resource_exists namespace "$namespace"
    resource_status=$?
    if [[ $resource_status -eq 1 ]]; then
      active_kubectl create namespace "$namespace" >/dev/null || return 1
    elif [[ $resource_status -ne 0 ]]; then
      return "$resource_status"
    fi
    resource_exists project "$project"
    resource_status=$?
    if [[ $resource_status -eq 1 ]]; then
      create_project_resource "$project" "$namespace" || return 1
      patch_project_status "$project" || return 1
    elif [[ $resource_status -ne 0 ]]; then
      return "$resource_status"
    fi
    for shoot in $(get_shoots "$workspace" "$project"); do
      resource_exists shoot "$shoot" -n "$namespace"
      resource_status=$?
      if [[ $resource_status -eq 0 ]]; then
        continue
      fi
      [[ $resource_status -eq 1 ]] || return "$resource_status"
      create_shoot "$shoot" "$namespace" || return 1
    done
    ensure_templated_resource secret "$RES_DIR/secret-template.yaml" aws-secret "$namespace" || return 1
    ensure_templated_resource secretbinding "$RES_DIR/secretbinding-template.yaml" aws-secret-binding "$namespace" || return 1
  done

  if [[ -e "$dashboard_single_cfg" ]]; then
    if [[ ! -f "$dashboard_single_cfg" || -L "$dashboard_single_cfg" ]]; then
      log_error "Error: dashboard kubeconfig '$dashboard_single_cfg' must be a regular, non-symlink file. Refusing to replace it."
      return 1
    fi
    if ! dashboard_kubeconfig_is_usable; then
      log_info "${YELLOW}Refreshing the unusable generated dashboard kubeconfig...${NC}"
      create_kubeconfig "$dashboard_single_cfg" "$workspace" || return 1
    fi
  else
    create_kubeconfig "$dashboard_single_cfg" "$workspace" || return 1
  fi

  log_info "${GREEN}single demo is ready; dashboard kubeconfig:${NC} $dashboard_single_cfg"
}

ensure_scenario_shoot() {
  local shoot="$1" namespace="$2" resource_status

  resource_exists shoot "$shoot" -n "$namespace"
  resource_status=$?
  if [[ $resource_status -eq 0 ]]; then
    return 0
  fi
  [[ $resource_status -eq 1 ]] || return "$resource_status"

  create_shoot "$shoot" "$namespace"
}

apply_named_scenario() {
  local scenario="$1"
  local scenario_shoot="pine-oak"
  local scenario_namespace="garden-pine"
  local number

  case "$scenario" in
    healthy-shoot)
      ensure_single_demo || return 1
      patch_shoot_ready "$scenario_shoot" "$scenario_namespace" || return 1
      ;;
    failing-shoot)
      ensure_single_demo || return 1
      patch_shoot_status_from_template "$scenario_shoot" "$scenario_namespace" \
        "${RES_DIR}/status-shoot-failing.yaml" || return 1
      ;;
    many-shoots)
      ensure_single_demo || return 1
      for number in {01..12}; do
        ensure_scenario_shoot "visual-many-${number}" "$scenario_namespace" || return 1
      done
      ;;
    operation-in-progress)
      ensure_single_demo || return 1
      patch_shoot_status_from_template "$scenario_shoot" "$scenario_namespace" \
        "${RES_DIR}/status-shoot-operation-in-progress.yaml" || return 1
      ;;
    *)
      log_error "Error: unknown scenario '$scenario'. Choose healthy-shoot, failing-shoot, many-shoots, or operation-in-progress."
      return 1
      ;;
  esac

  log_info "${GREEN}scenario '${scenario}' is ready in the local demo fixture.${NC}"
}

status_line() {
  printf '%-28s %s\n' "$1" "$2"
}

status_command_prerequisite() {
  local label="$1" command_name="$2"

  if command -v "$command_name" >/dev/null 2>&1; then
    status_line "$label" "available"
  else
    status_line "$label" "missing"
  fi
}

status_kcp_process() {
  local process_ids

  if [[ ! -x "$KCP_BINARY" ]]; then
    status_line "kcp process:" "not checked (kcp binary is missing or not executable)"
    return
  fi

  if ! command -v pgrep >/dev/null 2>&1; then
    status_line "kcp process:" "not checked (pgrep is unavailable)"
    return
  fi

  if process_ids=$(command pgrep -f "$KCP_BINARY" 2>/dev/null); then
    process_ids="${process_ids//$'\n'/,}"
    status_line "kcp process:" "running (pid(s): $process_ids)"
  else
    status_line "kcp process:" "stopped"
  fi
}

status_selected_workspace() {
  local server="$1" context="$2" workspace

  if [[ "$server" == */clusters/* ]]; then
    workspace="${server#*/clusters/}"
    workspace="${workspace%%[/?#]*}"
    if [[ -n "$workspace" ]]; then
      printf '%s' "$workspace"
      return
    fi
  fi

  if [[ -n "$context" ]]; then
    printf '%s (inferred from current context)' "$context"
  else
    printf 'unavailable'
  fi
}

status_resource_count() {
  local resource="$1"
  local result line count=0
  shift

  if ! result=$(active_kubectl --request-timeout=5s get "$resource" "$@" --no-headers 2>/dev/null); then
    printf 'unavailable'
    return
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] && ((count += 1))
  done <<<"$result"
  printf '%s' "$count"
}

show_status() {
  local context server workspace projects shoots seeds cloudprofiles

  printf 'Gardenerless status (read-only)\n'
  status_line "Runtime directory:" "$KCP_DIR"
  if [[ -d "$KCP_DIR" ]]; then
    status_line "Runtime state:" "present"
  else
    status_line "Runtime state:" "absent"
  fi
  status_line "Expected kcp release:" "$KCP_RELEASE"
  status_line "Expected kcp commit:" "$KCP_COMMIT"
  if verify_kcp_checkout; then
    status_line "kcp source provenance:" "verified (detached ${KCP_VERIFIED_COMMIT})"
  else
    status_line "kcp source provenance:" "${KCP_VERIFY_STATUS} (${KCP_VERIFY_ERROR})"
  fi

  status_line "Prerequisites:" ""
  status_command_prerequisite "  git:" git
  status_command_prerequisite "  go:" go
  status_command_prerequisite "  make:" make
  status_command_prerequisite "  kubectl:" kubectl
  status_command_prerequisite "  yq:" yq
  status_command_prerequisite "  openssl:" openssl
  if [[ -x "$KCP_KUBECTL_WS_BINARY" || -x "$KCP_KUBECTL_KCP_BINARY" ]]; then
    status_line "  kubectl workspace plugin:" "available"
  else
    status_line "  kubectl workspace plugin:" "missing"
  fi
  if [[ -x "$KCP_BINARY" ]]; then
    status_line "kcp binary:" "available ($KCP_BINARY)"
  else
    status_line "kcp binary:" "missing or not executable ($KCP_BINARY)"
  fi
  status_kcp_process

  if [[ -n "$WORKSPACE_PARAM" ]]; then
    status_line "Workspace override:" "ignored for read-only status"
  fi

  if ! init_kubeconfig; then
    status_line "Guarded kubeconfig:" "unavailable"
    status_line "API readiness:" "unavailable (explicit kubeconfig validation failed; no API request was made)"
    status_line "Selected context:" "unavailable"
    status_line "Selected workspace:" "unavailable"
    status_line "Demo resources:" "unavailable"
    return 0
  fi

  status_line "Guarded kubeconfig:" "$ACTIVE_GARDENERLESS_KUBECONFIG"
  if ! context=$(active_kubectl config current-context 2>/dev/null); then
    context="unavailable"
  fi
  if ! server=$(active_kubectl config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null); then
    server=""
  fi
  workspace=$(status_selected_workspace "$server" "$context")
  status_line "Selected context:" "$context"
  status_line "Selected workspace:" "$workspace"

  if ! active_kubectl --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1; then
    status_line "API readiness:" "unavailable"
    status_line "Demo resources:" "unavailable (API is not ready)"
    return 0
  fi

  status_line "API readiness:" "ready"
  projects=$(status_resource_count projects)
  shoots=$(status_resource_count shoots -A)
  seeds=$(status_resource_count seeds)
  cloudprofiles=$(status_resource_count cloudprofiles)
  status_line "Demo resources:" "projects=$projects, shoots=$shoots, seeds=$seeds, cloudprofiles=$cloudprofiles"
}

command_contacts_kubernetes_api() {
  case "$1" in
    status|\
    setup-gardener-crds|\
    cluster-resources|\
    get-token|\
    create-demo-workspaces|\
    ensure-single-demo-workspace|\
    scenario|\
    add-project|\
    add-shoot|\
    add-projects|\
    add-shoots)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

show_help() {
  cat <<EOF
${BLUE}Usage:${NC} $0 <command> [options]

This tool operates on the kcp admin.kubeconfig. It works with the workspace set in this KUBECONFIG.
You can overwrite the workspace using the ${YELLOW}--workspace|-ws <ws>${NC} option.
The script only operates on workspaces directly under root (no deep nesting).
${GREEN}create-demo-workspaces${NC} always creates its demo workspaces under root.

Commands:
  ${GREEN}setup-kcp${NC}
      Fetch verified kcp ${KCP_RELEASE} and build repository-local binaries

  ${GREEN}start-kcp${NC}
      Start kcp server (foreground)

  ${GREEN}reset-kcp${NC}
      Delete .kcp state

  ${GREEN}reset-kcp-certs${NC}
      Delete cert/key files in .kcp

  ${GREEN}setup-gardener-crds${NC}
      Apply Gardener CRDs in the current workspace

  ${GREEN}cluster-resources${NC}
      Apply cloudprofile & seed YAMLs

  ${GREEN}get-token${NC}
      ${YELLOW}[--service-account|-sa NAME]${NC}
      Print service account token (default: dashboard-user)

  ${GREEN}dashboard-kubeconfigs${NC}
      Print paths of dashboard kubeconfigs

  ${GREEN}status${NC}
      Read-only local runtime, guarded API, and demo-resource status

  ${GREEN}verify-kcp${NC}
      ${YELLOW}--format=json${NC}
      Verify the selected kcp checkout and binary; print schema-versioned JSON

  ${GREEN}create-demo-workspaces${NC}
      Build demo workspaces (animals/plants/cars)

  ${GREEN}ensure-single-demo-workspace${NC}
      Create only missing resources for the local demo workspace

  ${GREEN}scenario${NC}
      ${YELLOW}<healthy-shoot|failing-shoot|many-shoots|operation-in-progress>${NC}
      Apply one named local demo fixture state for dashboard verification

  ${GREEN}add-project${NC}
      ${YELLOW}--name|-n NAME [--namespace|-N NAMESPACE]${NC}
      Add a project (status=ready)

  ${GREEN}add-shoot${NC}
      ${YELLOW}--shoot|-s SHOOT --project|-p PROJECT${NC}
      Add one shoot to a project

  ${GREEN}add-projects${NC}
      ${YELLOW}--count|-c COUNT${NC}
      Bulk create N projects

  ${GREEN}add-shoots${NC}
      ${YELLOW}--project|-p PROJECT --count|-c COUNT${NC}
      Bulk create N shoots in a project

Options:
  ${YELLOW}-h, --help${NC}
      Show this help message and exit

Environment:
  ${YELLOW}GARDENERLESS_KCP_DIR${NC}
      kcp source/runtime directory (default: ${SCRIPT_DIR}/kcp)
EOF
  exit "${1:-0}"
}

# ────────────────────────────────────────────────
# 1) Global flags
WORKSPACE_PARAM=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace|-ws)
      if [[ -n "$2" && "${2:0:1}" != "-" ]]; then
        WORKSPACE_PARAM="$2"
        shift 2
      else
        echo -e "${RED}Error: --workspace requires a value${NC}" >&2
        exit 1
      fi
      ;;
    -h|--help)
      show_help
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

set -- "${ARGS[@]}"

# 2) Sub-command
if [[ $# -lt 1 ]]; then show_help; fi
COMMAND="$1"; shift

# 3) Guard API-facing commands before applying any global workspace.
if command_contacts_kubernetes_api "$COMMAND"; then
  # status reports local diagnostics before attempting validation and never
  # changes workspaces, even when a global --workspace option was supplied.
  if [[ "$COMMAND" != "status" ]]; then
    if ! init_kubeconfig; then
      exit 1
    fi
    if [[ -n "$WORKSPACE_PARAM" ]]; then
      IFS=':' read -ra parts <<<"$WORKSPACE_PARAM"
      [[ "${parts[0]}" != "root" ]] && parts=(root "${parts[@]}")
      switch_to_root
      for ws in "${parts[@]:1}"; do
        run_quiet active_kubectl ws "$ws"
      done
    fi
  fi
fi

# 4) Dispatch & per-command flag parsing
case "$COMMAND" in
  setup-kcp)
    setup_kcp
    ;;

  start-kcp)
    start_kcp_server
    ;;

  reset-kcp)        
    rm -rf "$KCP_STATE_DIR"
    ;;

  reset-kcp-certs)
    rm -f "$KCP_STATE_DIR"/*.crt "$KCP_STATE_DIR"/*.key
    ;;

  setup-gardener-crds)
    setup_gardener_crds
    ;;

  cluster-resources)
    apply_cluster_resources
    ;;

  get-token)
    SA_NAME="dashboard-user"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --service-account|-sa) SA_NAME="$2"; shift 2;;
        -h|--help) show_help;;
        *) log_error "Unknown option: $1"; exit 1;;
      esac
    done
    active_kubectl -n garden create token "$SA_NAME" --duration 24h
    ;;

  dashboard-kubeconfigs)
    log_info "kcp-mode dashboard kubeconfig : $dashboard_kcp_cfg"
    log_info "single-workspace dashboard   : $dashboard_single_cfg"
    ;;

  status)
    show_status
    ;;

  verify-kcp)
    if [[ $# -ne 1 || "$1" != "--format=json" ]]; then
      log_error "Error: verify-kcp requires exactly '--format=json'."
      exit 1
    fi
    verify_kcp_json
    ;;

  create-demo-workspaces)
    create_demo_ws demo-animals || exit 1
    create_demo_ws demo-plants || exit 1
    create_demo_ws demo-cars || exit 1
    create_kubeconfig "$dashboard_kcp_cfg" base || exit 1
    log_info "${GREEN}dashboard-kcp kubeconfig:${NC} $dashboard_kcp_cfg"
    ;;

  ensure-single-demo-workspace)
    ensure_single_demo
    ;;

  scenario)
    if [[ $# -ne 1 ]]; then
      log_error "Error: scenario requires exactly one scenario name."
      show_help 1
    fi
    apply_named_scenario "$1"
    ;;

  add-project)
    NAME=""; NAMESPACE=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace|-ws) shift 2;;           # allow global anywhere
        --name|-n)      NAME="$2"; shift 2;;
        --namespace|-N) NAMESPACE="$2"; shift 2;;
        -h|--help)      show_help;;
        *) log_error "Unknown option: $1"; exit 1;;
      esac
    done
    [[ -z "$NAME" ]] && { log_error "Missing --name"; exit 1; }
    NAMESPACE="garden-${NAMESPACE:-$NAME}"
    run_silent active_kubectl get ns "$NAMESPACE" || active_kubectl create ns "$NAMESPACE"
    create_project_resource "$NAME" "$NAMESPACE"
    patch_project_status "$NAME"
    ;;

  add-shoot)
    SHOOT=""; PROJECT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace|-ws) shift 2;;           # allow global anywhere
        --shoot|-s)    SHOOT="$2";    shift 2;;
        --project|-p)  PROJECT="$2";  shift 2;;
        -h|--help)     show_help;;
        *) log_error "Unknown option: $1"; exit 1;;
      esac
    done
    [[ -z "$SHOOT" || -z "$PROJECT" ]] && { log_error "Missing --shoot or --project"; exit 1; }
    ns="garden-${PROJECT}"
    log_info "${YELLOW}Adding shoot '$SHOOT' to project '$PROJECT'...${NC}"
    create_shoot "$SHOOT" "$ns"
    ;;

  add-projects)
    COUNT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace|-ws) shift 2;;
        --count|-c)      COUNT="$2"; shift 2;;
        -h|--help)       show_help;;
        *) log_error "Unknown option: $1"; exit 1;;
      esac
    done
    [[ -z "$COUNT" ]] && { log_error "Missing --count"; exit 1; }
    bulk_projects "$COUNT"
    ;;

  add-shoots)
    PROJECT=""; COUNT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace|-ws) shift 2;;
        --project|-p)    PROJECT="$2"; shift 2;;
        --count|-c)      COUNT="$2";   shift 2;;
        -h|--help)       show_help;;
        *) log_error "Unknown option: $1"; exit 1;;
      esac
    done
    [[ -z "$PROJECT" || -z "$COUNT" ]] && { log_error "Missing --project or --count"; exit 1; }
    bulk_shoots "$PROJECT" "$COUNT"
    ;;
  *)
    log_error "${RED}Unknown command: $COMMAND${NC}"
    show_help 1
    ;;
esac
