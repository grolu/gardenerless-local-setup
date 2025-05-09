#!/bin/bash

set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RES_DIR="${SCRIPT_DIR}/resources"
KCP_DIR="${SCRIPT_DIR}/kcp"
KCP_REPO="https://github.com/kcp-dev/kcp.git"
ORIG_KUBECONFIG="${KCP_DIR}/.kcp/admin.kubeconfig"

dashboard_kcp_cfg="${KCP_DIR}/.kcp/dashboard-kcp.kubeconfig"
dashboard_single_cfg="${KCP_DIR}/.kcp/dashboard.kubeconfig"

# -------------------------------------------------
# Quiet / silent wrappers --------------------------------
run_quiet()  { "$@" >/dev/null; }
run_silent() { "$@" >/dev/null 2>&1; }
# -------------------------------------------------

init_temp_kubeconfig() {
    TMP_KUBECONFIG=$(mktemp)
    cp "$ORIG_KUBECONFIG" "$TMP_KUBECONFIG"
    export KUBECONFIG="$TMP_KUBECONFIG"
    trap "rm -f $TMP_KUBECONFIG" EXIT
}

switch_to_root() {
    run_quiet kubectl config use-context root
    run_quiet kubectl ws :root
}

apply_yaml_template() {
    sed -e "s/NAMESPACEPLACEHOLDER/$3/g" -e "s/NAMEPLACEHOLDER/$2/g" "$1"
}

# ----------------------------------------------------
# create_kubeconfig <dest> <workspace>
# ----------------------------------------------------
create_kubeconfig() {
    local dest="$1"; local ws="$2"
    echo -e "${YELLOW}Creating kubeconfig for workspace '$ws'...${NC}"
    cp "$TMP_KUBECONFIG" "$dest"

    # always start from the root workspace
    run_quiet env KUBECONFIG="$dest" kubectl config use-context root
    run_quiet env KUBECONFIG="$dest" kubectl ws :root

    # if we're targeting a non-base workspace, pre-switch into root:<ws>
    if [[ "$ws" != "base" ]]; then
        run_quiet env KUBECONFIG="$dest" kubectl ws ":root:$ws"
    fi

    # now try to use the workspace-named context…
    if ! run_silent env KUBECONFIG="$dest" kubectl config use-context "$ws"; then
        # …and if it doesn't exist yet, rename whatever current-context is into $ws
        cur=$(env KUBECONFIG="$dest" kubectl config current-context)
        run_quiet env KUBECONFIG="$dest" kubectl config rename-context "$cur" "$ws"
        run_quiet env KUBECONFIG="$dest" kubectl config use-context "$ws"
    fi
}

setup_gardener_crds() {
    echo -e "${YELLOW}Setting up Gardener CRDs...${NC}"
    run_quiet kubectl apply -f "${SCRIPT_DIR}/crds/"
    echo -e "${GREEN}Gardener CRDs set up successfully.${NC}"
    echo -e "${YELLOW}Waiting 5 seconds for APIs to become available...${NC}"
    sleep 5
}

apply_cluster_resources() {
    echo -e "${YELLOW}Applying cluster resources...${NC}"
    run_quiet kubectl apply -f "$RES_DIR/cloudprofile-*.yaml"
    run_quiet kubectl apply -f "$RES_DIR/seed-*.yaml"
}

create_project_resource() {
    echo -e "${YELLOW}Creating project resource '$1'...${NC}"
    apply_yaml_template "${RES_DIR}/project-template.yaml" "$1" "$2" | kubectl apply -f - >/dev/null
}

patch_project_status() {
    echo -e "${YELLOW}Marking project '$1' as Ready...${NC}"
    run_quiet kubectl patch project "$1" --type=merge --subresource=status -p '{"status":{"phase":"Ready"}}'
}

setup_kcp() {
    if [ -d "$KCP_DIR" ]; then
        echo -e "${YELLOW}Resetting kcp repo to latest HEAD...${NC}"
        run_quiet git -C "$KCP_DIR" fetch --all
        run_quiet git -C "$KCP_DIR" reset --hard origin/main
    else
        echo -e "${YELLOW}Cloning kcp repo...${NC}"
        run_quiet git clone "$KCP_REPO" "$KCP_DIR"
    fi
    echo -e "${YELLOW}Building kcp...${NC}"
    export IGNORE_GO_VERSION=1
    (cd "$KCP_DIR" && run_quiet make build)
    echo -e "${GREEN}kcp built successfully.${NC}"
}

configure_macos_alias() {
    if [ "$(uname)" = "Darwin" ] && ! ifconfig lo0 | grep -q "192.168.65.1"; then
        echo -e "${YELLOW}Adding lo0 alias 192.168.65.1/24 (sudo)...${NC}"
        sudo ifconfig lo0 alias 192.168.65.1/24 >/dev/null
    fi
}

start_kcp_server() {
    pgrep -f "$KCP_DIR/bin/kcp" && { echo -e "${GREEN}kcp server already running.${NC}"; exit 0; }
    configure_macos_alias
    echo -e "${YELLOW}Starting kcp server...${NC}"
    cd "$KCP_DIR"
    exec ./bin/kcp start --bind-address=192.168.65.1
}

get_shoots() {
    case "$1:$2" in
        demo-animals:cat) echo "cat-alpha cat-error" ;;
        demo-animals:dog) echo "dog-alpha dog-error" ;;
        demo-plants:pine) echo "pine-oak pine-error" ;;
        demo-plants:rose) echo "rose-blossom rose-error" ;;
        demo-plants:sunflower) echo "sunflower-sunny sunflower-error" ;;
        demo-cars:bmw) echo "bmw-m3 bmw-x5 bmw-error" ;;
        demo-cars:mercedes) echo "merc-c300 merc-e350 merc-error" ;;
        demo-cars:tesla) echo "tesla-model3 tesla-models tesla-error" ;;
        demo:pine) echo "pine-oak pine-error" ;;
        demo:rose) echo "rose-blossom rose-error" ;;
        demo:sunflower) echo "sunflower-sunny sunflower-error" ;;
    esac
}

show_help() {
    cat <<EOF
$(echo -e "${BLUE}Usage:${NC}") $0 [--workspace <ws>] <command> [args]

This tool operates on the kcp admin.kubeconfig. It works with the workspace set in this KUBECONFIG. 
You can overwrite the workspace using the $(echo -e "${YELLOW}--workspace <ws>${NC}") option. 
The script only operates on workspaces directly under root (no deep nesting). 
Exceptions are $(echo -e "${GREEN}create-demo-workspaces${NC}") and $(echo -e "${GREEN}create-single-demo-workspace${NC}"), 
which will always create the workspace under root.

Commands:
  $(echo -e "${GREEN}setup-kcp${NC}")                    Download & build kcp
  $(echo -e "${GREEN}start-kcp${NC}")                    Start kcp server (foreground)
  $(echo -e "${GREEN}reset-kcp${NC}")                    Delete .kcp state
  $(echo -e "${GREEN}reset-kcp-certs${NC}")              Delete cert/key files in .kcp
  $(echo -e "${GREEN}setup-gardener-crds${NC}")          Apply Gardener CRDs in the current workspace
  $(echo -e "${GREEN}create-demo-workspaces${NC}")       Build demo workspaces (animals/plants/cars) with resources
  $(echo -e "${GREEN}create-single-demo-workspace${NC}") Build one demo workspace with resources
  $(echo -e "${GREEN}add-project <name>${NC}")           Add a project resource with status=ready
  $(echo -e "${GREEN}add-shoot <shoot> <proj>${NC}")     Add one shoot resource to a project
  $(echo -e "${GREEN}add-projects <count>${NC}")         Bulk create N projects (project-0001..N)
  $(echo -e "${GREEN}add-shoots <proj> <count>${NC}")    Bulk create N shoots in a project
  $(echo -e "${GREEN}dashboard-kubeconfigs${NC}")        Print paths of dashboard kubeconfigs
  $(echo -e "${GREEN}cluster-resources${NC}")            Apply cloudprofile & seed yamls
  $(echo -e "${GREEN}get-token${NC}")                    Print dashboard-user service account token

EOF
    exit 0
}

# -------------------------------------------------
WORKSPACE_PARAM=""; COMMAND=""; ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) WORKSPACE_PARAM="$2"; shift 2 ;;
        -h|--help|help) show_help ;;
        *) [ -z "$COMMAND" ] && COMMAND="$1" || ARGS+=("$1"); shift ;;
    esac
done
[ -z "$COMMAND" ] && show_help

if [[ "$COMMAND" != "setup-kcp" && "$COMMAND" != "start-kcp" ]]; then
    if [ ! -f "$KCP_DIR/bin/kcp" ]; then
        echo -e "${RED}Missing kcp binary.\nPlease use 'setup-kcp' to download and build kcp first.${NC}"
        exit 1
    fi
fi

needs_kubeconfig=true
[[ "$COMMAND" =~ ^(setup-kcp|start-kcp|reset-kcp|reset-kcp-certs)$ ]] && needs_kubeconfig=false

if $needs_kubeconfig; then
    if ! pgrep -f "[k]cp" >/dev/null 2>&1; then
        echo -e "${RED}No running kcp server detected.\nPlease start one with 'start-kcp' first.${NC}"
        exit 1
    fi
    if [ ! -f "$ORIG_KUBECONFIG" ]; then
        echo -e "${RED}Missing admin kubeconfig.\nPlease use 'start-kcp' to run a local kcp server first.${NC}"
        exit 1
    fi
    init_temp_kubeconfig
fi

if [ -n "$WORKSPACE_PARAM" ]; then
    IFS=':' read -ra parts <<<"$WORKSPACE_PARAM"
    [ "${parts[0]}" != "root" ] && parts=("root" "${parts[@]}")
    switch_to_root
    for ws in "${parts[@]:1}"; do run_quiet kubectl ws "$ws"; done
fi

create_shoot () {
    local name=$1 ns=$2
    local statusError=false
    if [[ $name == *-error ]]; then
        statusError=true
    fi
    echo -e "${YELLOW}Creating shoot resource '$name' in namespace '$ns'...${NC}"
    apply_yaml_template "${RES_DIR}/shoot-template.yaml" "$name" "$ns" | kubectl apply -n "$ns" -f - >/dev/null
    if [ "$statusError" = true ]; then
        echo -e "${YELLOW}Marking shoot '$name' as Error...${NC}"
        patch_data=$(< "${RES_DIR}/shoot-status-error.yaml")
    else
        echo -e "${YELLOW}Marking shoot '$name' as Ready...${NC}"
        patch_data=$(< "${RES_DIR}/shoot-status-ready.yaml")
    fi
    patch_data=$(echo "$patch_data" | sed -e "s/NAMESPACEPLACEHOLDER/$ns/g" -e "s/NAMEPLACEHOLDER/$name/g")
    local json_patch=$(echo "$patch_data" | yq -o=json) 
    run_quiet kubectl patch shoot "$name" -n "$ns" --type=merge --subresource=status --patch "$json_patch"

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

# -------------------------------------------------
case "$COMMAND" in
    setup-kcp)        setup_kcp ;;
    start-kcp)        start_kcp_server ;;
    setup-gardener-crds) setup_gardener_crds ;;
    create-demo-workspaces)
        for dws in demo-animals demo-plants demo-cars; do create_demo_ws "$dws"; done
        create_kubeconfig "$dashboard_kcp_cfg" base
        echo -e "${GREEN}dashboard-kcp kubeconfig:${NC} $dashboard_kcp_cfg"
        ;;
    create-single-demo-workspace)
        wsname="demo"
        create_demo_ws "$wsname"
        create_kubeconfig "$dashboard_single_cfg" "$wsname"
        echo -e "${GREEN}dashboard kubeconfig:${NC} $dashboard_single_cfg"
        ;;
    dashboard-kubeconfigs)
        echo -e "kcp-mode dashboard kubeconfig : $dashboard_kcp_cfg"
        echo -e "single-workspace dashboard   : $dashboard_single_cfg"
        ;;
    add-project)
        [ ${#ARGS[@]} -lt 1 ] && { echo "project name required" >&2; exit 1; }
        NAMESPACE="garden-${ARGS[0]}"
        run_silent kubectl get ns "$NAMESPACE" || run_quiet kubectl create ns "$NAMESPACE"
        create_project_resource "${ARGS[0]}" "$NAMESPACE"
        patch_project_status "${ARGS[0]}"
        ;;
    add-shoot)
        [ ${#ARGS[@]} -lt 2 ] && { echo "usage: add-shoot <shoot> <project>" >&2; exit 1; }
        ns="garden-${ARGS[1]}"
        echo -e "${YELLOW}Adding shoot '${ARGS[0]}' to project '${ARGS[1]}'...${NC}"
        create_shoot "${ARGS[0]}" "$ns"
        ;;
    add-projects)
        [ ${#ARGS[@]} -lt 1 ] && { echo "usage: add-projects <count>" >&2; exit 1; }
        bulk_projects "${ARGS[0]}"
        ;;
    add-shoots)
        [ ${#ARGS[@]} -lt 2 ] && { echo "usage: add-shoots <project> <count>" >&2; exit 1; }
        bulk_shoots "${ARGS[0]}" "${ARGS[1]}"
        ;;
    cluster-resources)
        apply_cluster_resources
        ;;
    get-token)
        kubectl -n garden create token dashboard-user --duration 24h
        ;;
    reset-kcp)        rm -rf "$KCP_DIR/.kcp" ;;
    reset-kcp-certs)  rm -f "$KCP_DIR/.kcp"/*.crt "$KCP_DIR/.kcp"/*.key ;;
    *) echo -e "${RED}Unknown command${NC}"; show_help ;;
esac
