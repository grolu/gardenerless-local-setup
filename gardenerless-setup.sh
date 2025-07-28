#!/bin/bash
set -o pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# logging helpers (keep using echo -e for ANSI colors)
log_info()  { echo -e "$*";                  }
log_error() { echo -e "$*" >&2;              }

# timestamp helper
now()       { date -u +%Y-%m-%dT%H:%M:%SZ;    }

RES_DIR="${SCRIPT_DIR}/resources"
KCP_DIR="${SCRIPT_DIR}/kcp"
KCP_REPO="https://github.com/kcp-dev/kcp.git"
KCP_KUBECONFIG="${KCP_DIR}/.kcp/admin.kubeconfig"
dashboard_kcp_cfg="${KCP_DIR}/.kcp/dashboard-kcp.kubeconfig"
dashboard_single_cfg="${KCP_DIR}/.kcp/dashboard.kubeconfig"

# quiet / silent wrappers
run_quiet()  { "$@" >/dev/null; }
run_silent() { "$@" >/dev/null 2>&1; }

init_kubeconfig() {
  KUBECONFIG="${KCP_KUBECONFIG}"
}

switch_to_root() {
  run_quiet kubectl config use-context root
  run_quiet kubectl ws :root
}

apply_yaml_template() {
  sed -e "s/NAMESPACEPLACEHOLDER/$3/g" \
      -e "s/NAMEPLACEHOLDER/$2/g" "$1"
}

create_kubeconfig() {
  local dest="$1" ws="$2"
  log_info "${YELLOW}Creating kubeconfig for workspace '$ws'...${NC}"
  cp "$KCP_KUBECONFIG" "$dest"
  run_quiet env KUBECONFIG="$dest" kubectl config use-context root
  run_quiet env KUBECONFIG="$dest" kubectl ws :root
  if [[ "$ws" != "base" ]]; then
    run_quiet env KUBECONFIG="$dest" kubectl ws ":root:$ws"
  fi
  if ! run_silent env KUBECONFIG="$dest" kubectl config use-context "$ws"; then
    cur=$(env KUBECONFIG="$dest" kubectl config current-context)
    run_quiet env KUBECONFIG="$dest" kubectl config rename-context "$cur" "$ws"
    run_quiet env KUBECONFIG="$dest" kubectl config use-context "$ws"
  fi
}

setup_gardener_crds() {
  log_info "${YELLOW}Setting up Gardener CRDs...${NC}"
  run_quiet kubectl apply -f "${SCRIPT_DIR}/crds/"
  log_info "${GREEN}Gardener CRDs set up successfully.${NC}"
  log_info "${YELLOW}Waiting 5 seconds for APIs to become available...${NC}"
  sleep 5
}

apply_cluster_resources() {
  log_info "${YELLOW}Applying cluster resources...${NC}"
  run_quiet kubectl apply -f "$RES_DIR/cloudprofile-*.yaml"
  run_quiet kubectl apply -f "$RES_DIR/seed-*.yaml"
  for f in "$RES_DIR"/seed-*.yaml; do
    name=$(yq e '.metadata.name' "$f")
    patch_seed_status "$name"
  done
}

create_project_resource() {
  log_info "${YELLOW}Creating project resource '$1'...${NC}"
  apply_yaml_template "$RES_DIR/project-template.yaml" "$1" "$2" \
    | run_quiet kubectl apply -f -
}

patch_project_status() {
  log_info "${YELLOW}Marking project '$1' as Ready...${NC}"
  run_quiet kubectl patch project "$1" \
    --type=merge --subresource=status -p '{"status":{"phase":"Ready"}}'
}

patch_shoot_ready() {
  local shoot="$1" ns="$2"
  local project="${ns#garden-}"
  local now="$(now)"
  local patch_yaml
  patch_yaml=$(apply_yaml_template "${RES_DIR}/shoot-status-ready.yaml" "$shoot" "$ns" | sed -E "s/DATEPLACEHOLDER/${now}/g")
  local json_patch
  json_patch=$(echo "$patch_yaml" | yq -o=json)
  run_quiet kubectl patch shoot "$shoot" -n "$ns" --type=merge --subresource=status -p "$json_patch"
  run_quiet kubectl label shoot "$shoot" -n "$ns" shoot.gardener.cloud/status="healthy" --overwrite
}

patch_seed_status() {
  local seed="$1"
  local now="$(now)"
  local patch_yaml
  patch_yaml=$(sed -e "s/DATEPLACEHOLDER/${now}/g" "$RES_DIR/seed-status.yaml")
  local json_patch
  json_patch=$(echo "$patch_yaml" | yq -o=json)
  run_quiet kubectl patch seed "$seed" --type=merge --subresource=status -p "$json_patch"
}

setup_kcp() {
  if [ -d "$KCP_DIR" ]; then
    log_info "${YELLOW}Resetting kcp repo to latest HEAD...${NC}"
    run_quiet git -C "$KCP_DIR" fetch --all
    run_quiet git -C "$KCP_DIR" reset --hard origin/main
  else
    log_info "${YELLOW}Cloning kcp repo...${NC}"
    run_quiet git clone "$KCP_REPO" "$KCP_DIR"
  fi
  log_info "${YELLOW}Building kcp...${NC}"
  export IGNORE_GO_VERSION=1
  (cd "$KCP_DIR" && run_quiet make build)
  log_info "${GREEN}kcp built successfully.${NC}"
}

configure_macos_alias() {
  if [[ "$(uname)" == "Darwin" ]] && ! ifconfig lo0 | grep -q "192.168.65.1"; then
    log_info "${YELLOW}Adding lo0 alias 192.168.65.1/24 (sudo)...${NC}"
    sudo ifconfig lo0 alias 192.168.65.1/24 >/dev/null
  fi
}

start_kcp_server() {
  if pgrep -f "$KCP_DIR/bin/kcp"; then
    log_info "${GREEN}kcp server already running.${NC}"
    exit 0
  fi
  configure_macos_alias
  log_info "${YELLOW}Starting kcp server...${NC}"
  cd "$KCP_DIR"
  exec ./bin/kcp start --bind-address=192.168.65.1
}

get_shoots() {
  case "$1:$2" in
    demo-animals:cat)        echo "cat-alpha cat-error"      ;;
    demo-animals:dog)        echo "dog-alpha dog-error"      ;;
    demo-plants:pine)        echo "pine-oak pine-error"      ;;
    demo-plants:rose)        echo "rose-blossom rose-error"  ;;
    demo-plants:sunflower)   echo "sunflower-sunny sunflower-error" ;;
    demo-cars:bmw)           echo "bmw-m3 bmw-x5 bmw-error"  ;;
    demo-cars:mercedes)      echo "merc-c300 merc-e350 merc-error" ;;
    demo-cars:tesla)         echo "tesla-model3 tesla-models tesla-error" ;;
    demo:pine)               echo "pine-oak pine-error"      ;;
    demo:rose)               echo "rose-blossom rose-error"  ;;
    demo:sunflower)          echo "sunflower-sunny sunflower-error" ;;
  esac
}

# toggles a single shoot between ready and error

# every $interval seconds, pick a random shoot (optionally per project) and flip it

# simulate a long-running operation (Processing→Succeeded)

create_shoot () {
    local name=$1 ns=$2
    log_info "${YELLOW}Creating shoot resource '$name' in namespace '$ns'...${NC}"
    apply_yaml_template "${RES_DIR}/shoot-template.yaml" "$name" "$ns" | kubectl apply -n "$ns" -f - >/dev/null
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
        run_silent kubectl get ns "$NAMESPACE" || run_quiet kubectl create ns "$NAMESPACE"
        create_project_resource "$name" "$NAMESPACE"
        patch_project_status "$name"
    done
}

bulk_shoots() {
    local proj=$1 count=$2
    local ns="garden-$proj"
    if ! run_silent kubectl get ns "$ns"; then
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
    switch_to_root
    run_silent kubectl ws create "$ws" --enter || run_quiet kubectl ws "$ws"
    echo -e "${YELLOW}Setting up dashboard-suer service account...${NC}"
    run_quiet kubectl create ns garden
    run_quiet kubectl create sa dashboard-user -n garden
    run_quiet kubectl create clusterrolebinding cluster-admin --clusterrole=cluster-admin --serviceaccount=garden:dashboard-user
    run_quiet kubectl set subject clusterrolebinding cluster-admin --serviceaccount=garden:dashboard-user
    setup_gardener_crds
    apply_cluster_resources
    case "$ws" in
        demo-animals) projects="cat dog" ;;
        demo-plants)  projects="pine rose sunflower" ;;
        demo)         projects="pine rose sunflower" ;;
        demo-cars)    projects="bmw mercedes tesla" ;;
    esac
    for proj in $projects; do
        ns="garden-${proj}"
        run_silent kubectl get ns "$ns" || run_quiet kubectl create ns "$ns"
        create_project_resource "$proj" "$ns"
        patch_project_status "$proj"
        for shoot in $(get_shoots "$ws" "$proj"); do
            create_shoot "$shoot" "$ns"
        done
        apply_yaml_template "${RES_DIR}/secret-template.yaml" "aws-secret" "$ns" | kubectl apply -n "$ns" -f - >/dev/null
        apply_yaml_template "${RES_DIR}/secretbinding-template.yaml" "aws-secret-binding" "$ns" | kubectl apply -n "$ns" -f - >/dev/null
    done
}

show_help() {
  cat <<EOF
${BLUE}Usage:${NC} $0 <command> [options]

This tool operates on the kcp admin.kubeconfig. It works with the workspace set in this KUBECONFIG.
You can overwrite the workspace using the ${YELLOW}--workspace|-ws <ws>${NC} option.
The script only operates on workspaces directly under root (no deep nesting).
Exceptions are ${GREEN}create-demo-workspaces${NC} and ${GREEN}create-single-demo-workspace${NC},
which will always create the workspaces under root.

Commands:
  ${GREEN}setup-kcp${NC}
      Download & build kcp

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
      Print dashboard-user service account token

  ${GREEN}dashboard-kubeconfigs${NC}
      Print paths of dashboard kubeconfigs

  ${GREEN}create-demo-workspaces${NC}
      Build demo workspaces (animals/plants/cars)

  ${GREEN}create-single-demo-workspace${NC}
      Build one demo workspace

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

  ${GREEN}toggle-shoot-status${NC}
      ${YELLOW}--shoot|-s SHOOT --project|-p PROJECT --mode|-m MODE${NC}
      Toggle a single shoot's status (ready|error)

  ${GREEN}random-update-shoots${NC}
      ${YELLOW}[--project|-p PROJECT] --interval|-i INTERVAL${NC}
      Periodically flip one shoot’s status

  ${GREEN}simulate-shoot-op${NC}
      ${YELLOW}--shoot|-s SHOOT --project|-p PROJECT --interval|-i INTERVAL [--step|-t STEP]${NC}
      Simulate lastOperation.progress →100

Options:
  ${YELLOW}-h, --help${NC}
      Show this help message and exit
EOF
  exit 0
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

# 3) Init kubeconfig & apply global workspace
if [[ "$COMMAND" != "setup-kcp" && "$COMMAND" != "start-kcp" ]]; then
  init_kubeconfig
  if [[ -n "$WORKSPACE_PARAM" ]]; then
    IFS=':' read -ra parts <<<"$WORKSPACE_PARAM"
    [[ "${parts[0]}" != "root" ]] && parts=(root "${parts[@]}")
    switch_to_root
    for ws in "${parts[@]:1}"; do
      run_quiet kubectl ws "$ws"
    done
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
    rm -rf "$KCP_DIR/.kcp"
    ;;

  reset-kcp-certs)
    rm -f "$KCP_DIR/.kcp"/*.crt "$KCP_DIR/.kcp"/*.key
    ;;

  setup-gardener-crds)
    setup_gardener_crds
    ;;

  cluster-resources)
    apply_cluster_resources
    ;;

  get-token)
    kubectl -n garden create token dashboard-user --duration 24h
    ;;

  dashboard-kubeconfigs)
    log_info "kcp-mode dashboard kubeconfig : $dashboard_kcp_cfg"
    log_info "single-workspace dashboard   : $dashboard_single_cfg"
    ;;

  create-demo-workspaces)
    create_demo_ws demo-animals
    create_demo_ws demo-plants
    create_demo_ws demo-cars
    create_kubeconfig "$dashboard_kcp_cfg" base
    log_info "${GREEN}dashboard-kcp kubeconfig:${NC} $dashboard_kcp_cfg"
    ;;

  create-single-demo-workspace)
    create_demo_ws demo
    create_kubeconfig "$dashboard_single_cfg" demo
    log_info "${GREEN}dashboard kubeconfig:${NC} $dashboard_single_cfg"
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
    run_silent kubectl get ns "$NAMESPACE" || kubectl create ns "$NAMESPACE"
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
    show_help
    ;;
esac
