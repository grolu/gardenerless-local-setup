#!/bin/bash
# ====================================
# kcp Local Management Script (Temporary KUBECONFIG version)
# ====================================

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Determine the directory of this script (for templates and CRD scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine the original kubeconfig file (default to ~/.kube/config if not set)
ORIG_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Sanity check: Ensure the original kubeconfig appears to be for a local kcp setup (must contain "kcp-admin")
if ! grep -q "kcp-admin" "$ORIG_KUBECONFIG"; then
    echo -e "${RED}Error: The current KUBECONFIG does not appear to be for a local kcp setup (missing 'kcp-admin').${NC}"
    exit 1
fi

# ----------------------------------------------------------------------------
# Global Initialization: Always use a temporary KUBECONFIG copy
# ----------------------------------------------------------------------------
init_temp_kubeconfig() {
    TMP_KUBECONFIG=$(mktemp)
    cp "$ORIG_KUBECONFIG" "$TMP_KUBECONFIG"
    export KUBECONFIG="$TMP_KUBECONFIG"
    trap "rm -f $TMP_KUBECONFIG" EXIT
}
init_temp_kubeconfig

# ----------------------------------------------------------------------------
# Function: switch_to_root
# ----------------------------------------------------------------------------
# This function switches the current context to root and ensures the workspace is set to :root.
switch_to_root() {
    kubectl config use-context root >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to switch context to 'root'.${NC}"
        exit 1
    fi
    kubectl ws :root >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# Template Helper Function
# ----------------------------------------------------------------------------
apply_yaml_template() {
    local template_file="$1"
    local resource_name="$2"
    local resource_namespace="$3"
    sed -e "s/NAMESPACEPLACEHOLDER/${resource_namespace}/g" -e "s/NAMEPLACEHOLDER/${resource_name}/g" "$template_file"
}

# ----------------------------------------------------------------------------
# Project Resource Functions
# ----------------------------------------------------------------------------
create_project_resource() {
    local project_name="$1"
    local namespace="$2"
    apply_yaml_template "${SCRIPT_DIR}/project-template.yaml" "$project_name" "$namespace" | kubectl apply -f - >/dev/null 2>&1
    return $?
}

patch_project_status() {
    kubectl patch project "$1" --type=merge --subresource=status -p '{"status": {"phase": "Ready"}}' >/dev/null 2>&1
    return $?
}

# ----------------------------------------------------------------------------
# Gardener CRDs Setup Function
# ----------------------------------------------------------------------------
setup_gardener_crds() {
    local crd_script="${SCRIPT_DIR}/gardener-crds/setup-garderner-api.sh"

    # Check if the script exists
    if [ ! -f "${crd_script}" ]; then
        echo -e "${YELLOW}Script ${crd_script} not found. Attempting to download from GitHub using your SSH key...${NC}"
        
        # Clean up any existing directory to avoid conflicts
        if [ -d "${SCRIPT_DIR}/gardener-crds" ]; then
            rm -rf "${SCRIPT_DIR}/gardener-crds"
        fi

        # Clone the repository into gardener-crds directory
        git clone git@github.com:platform-mesh/gardener-workspace.git "${SCRIPT_DIR}/gardener-crds"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to download Gardener CRDs repository from GitHub.${NC}"
            exit 1
        fi
        
        # Verify that the required script now exists
        if [ ! -f "${crd_script}" ]; then
            echo -e "${RED}Error: setup-garderner-api.sh not found after cloning repository.${NC}"
            exit 1
        fi
    fi

    echo -e "${YELLOW}Setting up Gardener CRDs using ${BLUE}${crd_script}${NC}"
    ( cd "${SCRIPT_DIR}/gardener-crds" && env KUBECONFIG="$KUBECONFIG" bash "setup-garderner-api.sh" >/dev/null 2>&1 )
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to set up Gardener CRDs.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Gardener CRDs set up successfully.${NC}"
    echo -e "${YELLOW}Waiting 5 seconds to ensure APIs are available...${NC}"
    sleep 5
}

# ----------------------------------------------------------------------------
# Function: get_shoots
# ----------------------------------------------------------------------------
# Given a demo workspace and project name, this function returns creative shoot names.
get_shoots() {
    local ws="$1"
    local proj="$2"
    if [ "$ws" == "demo-animals" ]; then
        if [ "$proj" == "cat" ]; then
            echo "cat-alpha cat-beta"
        elif [ "$proj" == "dog" ]; then
            echo "dog-alpha dog-beta"
        fi
    elif [ "$ws" == "demo-plants" ]; then
        if [ "$proj" == "pine" ]; then
            echo "pine-oak pine-maple"
        elif [ "$proj" == "rose" ]; then
            echo "rose-blossom rose-petal"
        elif [ "$proj" == "sunflower" ]; then
            echo "sunflower-sunny"
        fi
    elif [ "$ws" == "demo-cars" ]; then
        if [ "$proj" == "bmw" ]; then
            echo "bmw-m3 bmw-x5"
        elif [ "$proj" == "mercedes" ]; then
            echo "merc-c300 merc-e350"
        elif [ "$proj" == "tesla" ]; then
            echo "tesla-model3 tesla-models"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Help Function
# ----------------------------------------------------------------------------
show_help() {
    echo -e "${BLUE}Usage: $0 [--workspace <workspace>] <command> [command args]${NC}"
    echo ""
    echo -e "${BLUE}Global Options:${NC}"
    echo "  --workspace <workspace>    Specify the workspace (e.g. foo:bar or root:foo:bar)"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  setup-gardener-crds        Sets up Gardener CRDs for the current workspace"
    echo "  cluster-resources          Sets up Gardener CRDs and applies cluster resources (cloudprofile, seed)"
    echo "  get-token                  Ensures dashboard service account exists and returns a token for it"
    echo "  create-project <name>      Creates a project with the given project name"
    echo "  create-workspace <name>    Creates and enters a workspace"
    echo "  delete-workspace <name>    Deletes a workspace"
    echo "  list-workspaces            Lists all workspaces (kubectl ws tree)"
    echo "  reset-kcp                  Resets the local kcp installation (deletes bin/.kcp/*)"
    echo "  reset-kcp-certs            Resets only kcp certificate files (*.crt, *.key) in bin/.kcp/"
    echo "  create-demo-workspaces     Creates demo workspaces and projects with shoot/secret resources"
    echo ""
    echo "Examples:"
    echo "  $0 cluster-resources --workspace foo:bar"
    echo "  $0 get-token --workspace foo:bar"
    echo "  $0 create-project my_project --workspace root:foo:bar"
    echo "  $0 create-workspace myws --workspace foo:bar"
    echo "  $0 delete-workspace myws --workspace foo:bar"
    echo "  $0 list-workspaces --workspace foo:bar"
    echo "  $0 setup-gardener-crds --workspace foo:bar"
    echo "  $0 reset-kcp"
    echo "  $0 create-demo-workspaces"
    exit 0
}

# ----------------------------------------------------------------------------
# Parameter Parsing (Global Options and Command Dispatch)
# ----------------------------------------------------------------------------
WORKSPACE_PARAM=""
COMMAND=""
ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace)
            if [ -z "$2" ]; then
                echo -e "${RED}Error: --workspace flag requires a value (e.g. --workspace foo:bar).${NC}"
                exit 1
            fi
            WORKSPACE_PARAM="$2"
            shift 2
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            else
                ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

if [ -z "$COMMAND" ]; then
    show_help
fi

# ----------------------------------------------------------------------------
# Handle Workspace Option (if provided)
# ----------------------------------------------------------------------------
if [ -n "$WORKSPACE_PARAM" ]; then
    IFS=':' read -ra WS_PARTS <<< "$WORKSPACE_PARAM"
    if [ "${WS_PARTS[0]}" != "root" ]; then
        WS_PARTS=("root" "${WS_PARTS[@]}")
    fi
    switch_to_root
    for (( i=1; i<${#WS_PARTS[@]}; i++ )); do
        ws="${WS_PARTS[i]}"
        echo -e "${YELLOW}Entering workspace: ${BLUE}${ws}${NC}"
        kubectl ws "$ws" >/dev/null 2>&1 || kubectl ws "$ws" >/dev/null 2>&1
    done
    echo -e "${GREEN}Running commands in workspace: ${WS_PARTS[*]}${NC}"
fi

# ----------------------------------------------------------------------------
# Main Command Handling
# ----------------------------------------------------------------------------
case "$COMMAND" in
    help|-h|--help)
        show_help
        ;;
    setup-gardener-crds)
        setup_gardener_crds
        ;;
    cluster-resources)
        setup_gardener_crds
        echo -e "${GREEN}Applying cluster-resources...${NC}"
        kubectl apply -f cloudprofile.yaml >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to apply cloudprofile.yaml${NC}"
            exit 1
        fi
        kubectl apply -f seed.yaml >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to apply seed.yaml${NC}"
            exit 1
        fi
        echo -e "${GREEN}Cluster resources applied successfully.${NC}"
        ;;
    get-token)
        echo -e "${GREEN}Executing get-token command...${NC}"
        if ! kubectl get namespace garden >/dev/null 2>&1; then
            echo -e "${YELLOW}Namespace 'garden' does not exist. Creating it...${NC}"
            kubectl create namespace garden >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to create namespace 'garden'${NC}"
                exit 1
            fi
        fi
        if ! kubectl get serviceaccount dashboard-user -n garden >/dev/null 2>&1; then
            echo -e "${YELLOW}Service account 'dashboard-user' missing in namespace 'garden'. Creating it...${NC}"
            kubectl create serviceaccount dashboard-user -n garden >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to create service account 'dashboard-user' in namespace 'garden'${NC}"
                exit 1
            fi
        fi
        if ! kubectl get clusterrolebinding cluster-admin >/dev/null 2>&1; then
            echo -e "${YELLOW}Clusterrolebinding 'cluster-admin' missing. Creating it...${NC}"
            kubectl create clusterrolebinding cluster-admin --clusterrole=cluster-admin --serviceaccount=garden:dashboard-user >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to create clusterrolebinding 'cluster-admin'${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}Clusterrolebinding 'cluster-admin' exists. Updating subject...${NC}"
            kubectl set subject clusterrolebinding cluster-admin --serviceaccount=garden:dashboard-user >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to update clusterrolebinding 'cluster-admin'${NC}"
                exit 1
            fi
        fi
        TOKEN=$(kubectl -n garden create token dashboard-user --duration 24h 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$TOKEN" ]; then
            echo -e "${RED}Error: Failed to retrieve token for service account 'dashboard-user'${NC}"
            exit 1
        fi
        echo -e "${GREEN}Token for 'dashboard-user':${NC}"
        echo "$TOKEN"
        ;;
    create-project)
        if [ "${#ARGS[@]}" -lt 1 ]; then
            echo -e "${RED}Error: 'create-project' requires a project name as a parameter.${NC}"
            show_help
        fi
        PROJECT_NAME="${ARGS[0]}"
        NAMESPACE="garden-${PROJECT_NAME}"
        if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
            echo -e "${YELLOW}Creating namespace ${NAMESPACE}...${NC}"
            kubectl create namespace "${NAMESPACE}" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to create namespace ${NAMESPACE}${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}Namespace ${NAMESPACE} already exists. Skipping creation.${NC}"
        fi
        echo -e "${GREEN}Creating project resource '${PROJECT_NAME}' using template...${NC}"
        create_project_resource "${PROJECT_NAME}" "${NAMESPACE}"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to create project resource for '${PROJECT_NAME}'.${NC}"
            exit 1
        fi
        patch_project_status "${PROJECT_NAME}"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to patch project '${PROJECT_NAME}' status.${NC}"
            exit 1
        fi
        echo -e "${GREEN}Project '${PROJECT_NAME}' created and updated successfully.${NC}"
        ;;
    create-workspace)
        if [ "${#ARGS[@]}" -lt 1 ]; then
            echo -e "${RED}Error: 'create-workspace' requires a workspace name as a parameter.${NC}"
            show_help
        fi
        wsname="${ARGS[0]}"
        switch_to_root
        echo -e "${YELLOW}Creating workspace: ${BLUE}${wsname}${NC}"
        kubectl ws create "$wsname" --enter >/dev/null 2>&1 || { echo -e "${YELLOW}Workspace ${wsname} already exists; switching to it.${NC}"; kubectl ws "$wsname" >/dev/null 2>&1; }
        echo -e "${GREEN}Workspace ${wsname} is now active.${NC}"
        ;;
    delete-workspace)
        if [ "${#ARGS[@]}" -lt 1 ]; then
            echo -e "${RED}Error: 'delete-workspace' requires a workspace name as a parameter.${NC}"
            show_help
        fi
        wsname="${ARGS[0]}"
        switch_to_root
        echo -e "${YELLOW}Deleting workspace: ${BLUE}${wsname}${NC}"
        kubectl delete workspace "$wsname" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to delete workspace ${wsname}.${NC}"
            exit 1
        fi
        echo -e "${GREEN}Workspace ${wsname} deleted successfully.${NC}"
        ;;
    list-workspaces)
        switch_to_root
        echo -e "${GREEN}Listing workspaces:${NC}"
        kubectl ws tree
        ;;
    reset-kcp)
        if [[ "$ORIG_KUBECONFIG" == *"bin/.kcp/admin.kubeconfig" ]]; then
            local_kcp_dir=$(dirname "$ORIG_KUBECONFIG")
            rm -rf "${local_kcp_dir}"/* >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to reset local kcp installation in ${local_kcp_dir}.${NC}"
                exit 1
            else
                echo -e "${GREEN}Local kcp installation reset successfully in ${local_kcp_dir}.${NC}"
            fi
        else
            echo -e "${RED}Error: The kubeconfig does not point to a local binary kcp server.${NC}"
            exit 1
        fi
        ;;
    reset-kcp-certs)
        if [[ "$ORIG_KUBECONFIG" == *"bin/.kcp/admin.kubeconfig" ]]; then
            local_kcp_dir=$(dirname "$ORIG_KUBECONFIG")
            rm -f "${local_kcp_dir}"/*.crt "${local_kcp_dir}"/*.key >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to reset kcp certificates in ${local_kcp_dir}.${NC}"
                exit 1
            else
                echo -e "${GREEN}Local kcp certificates reset successfully in ${local_kcp_dir}.${NC}"
            fi
        else
            echo -e "${RED}Error: The kubeconfig does not point to a local binary kcp server.${NC}"
            exit 1
        fi
        ;;
    create-demo-workspaces)
        echo -e "${GREEN}Creating demo workspaces and projects...${NC}"
        switch_to_root
        demo_workspaces=("demo-animals" "demo-plants" "demo-cars")
        for ws in "${demo_workspaces[@]}"; do
            # Switch back to root before creating each demo workspace.
            switch_to_root
            echo -e "${YELLOW}Creating and entering demo workspace: root/${ws}${NC}"
            kubectl ws create "$ws" --enter >/dev/null 2>&1 || kubectl ws "$ws" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to create/enter demo workspace '$ws'.${NC}"
                exit 1
            fi
            setup_gardener_crds
            kubectl apply -f cloudprofile.yaml >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to apply cloudprofile.yaml in workspace '$ws'.${NC}"
                exit 1
            fi
            kubectl apply -f seed.yaml >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}Error: Failed to apply seed.yaml in workspace '$ws'.${NC}"
                exit 1
            fi
            echo -e "${GREEN}Cluster resources applied in workspace root/${ws}.${NC}"
            if [ "$ws" = "demo-animals" ]; then
                proj_list="cat dog"
            elif [ "$ws" = "demo-plants" ]; then
                proj_list="pine rose sunflower"
            elif [ "$ws" = "demo-cars" ]; then
                proj_list="bmw mercedes tesla"
            else
                proj_list=""
            fi
            for proj in $proj_list; do
                echo -e "${YELLOW}Creating project '${proj}' in workspace root/${ws}${NC}"
                ns="garden-${proj}"
                if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
                    kubectl create namespace "$ns" >/dev/null 2>&1
                    if [ $? -ne 0 ]; then
                        echo -e "${RED}Error: Failed to create namespace '$ns'.${NC}"
                        exit 1
                    fi
                fi
                create_project_resource "${proj}" "${ns}"
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Error: Failed to create project resource for '${proj}'.${NC}"
                    exit 1
                fi
                patch_project_status "${proj}"
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Error: Failed to patch project '${proj}' status.${NC}"
                    exit 1
                fi
                shoot_names=$(get_shoots "$ws" "$proj")
                for shoot in $shoot_names; do
                    echo -e "${YELLOW}Applying shoot resource '${shoot}' in namespace ${ns}${NC}"
                    apply_yaml_template "${SCRIPT_DIR}/shoot-template.yaml" "$shoot" "$ns" | kubectl apply -n "$ns" -f - >/dev/null 2>&1
                    if [ $? -ne 0 ]; then
                        echo -e "${RED}Error: Failed to apply shoot resource '${shoot}' in namespace ${ns}.${NC}"
                        exit 1
                    fi
                done
                echo -e "${YELLOW}Applying secret and secretbinding in namespace ${ns}${NC}"
                apply_yaml_template "${SCRIPT_DIR}/secret-template.yaml" "aws-secret" "$ns" | kubectl apply -n "$ns" -f - >/dev/null 2>&1
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Error: Failed to apply secret in namespace ${ns}.${NC}"
                    exit 1
                fi
                apply_yaml_template "${SCRIPT_DIR}/secretbinding-template.yaml" "aws-secret-binding" "$ns" | kubectl apply -n "$ns" -f - >/dev/null 2>&1
                if [ $? -ne 0 ]; then
                    echo -e "${RED}Error: Failed to apply secretbinding in namespace ${ns}.${NC}"
                    exit 1
                fi
            done
        done
        echo -e "${GREEN}Demo workspaces and projects created successfully.${NC}"
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$COMMAND'${NC}"
        show_help
        ;;
esac
