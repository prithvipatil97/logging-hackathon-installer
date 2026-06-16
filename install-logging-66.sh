#!/bin/bash
set -euo pipefail

########################################################################
# Logging 6.6 Hackathon Installer
# Automates the staging operator installation for RHOL 6.6 + Loki 6.6
# Compatible with: OCP 4.20, 4.21, 4.22
########################################################################

readonly SCRIPT_VERSION="1.1.0"
readonly SUPPORTED_OCP_VERSIONS="4.20|4.21|4.22"

readonly CLO_CATALOG_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:logging-6.6__v4.22__cluster-logging-rhel9-operator"
readonly LOKI_CATALOG_IMAGE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:logging-6.6__v4.22__loki-rhel9-operator"

STAGE_REGISTRY_TOKEN="${STAGE_REGISTRY_TOKEN:-}"
EMAIL=""
DRY_RUN=false
UNINSTALL=false
MCP_TIMEOUT=30
LOG_FILE=""

# --- Colors and output helpers ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC}   $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
step()    { echo -e "\n${GREEN}━━━ Step $1: $2 ━━━${NC}" | tee -a "$LOG_FILE"; }

# --- Usage ---

usage() {
    cat <<EOF
Logging 6.6 Hackathon Installer v${SCRIPT_VERSION}

Usage:
  $(basename "$0") [OPTIONS]

Options:
  --email EMAIL       Red Hat email prefix (e.g., "pripatil") [required for install]
  --token TOKEN       Base64-encoded stage registry token (or set STAGE_REGISTRY_TOKEN env var)
  --timeout MINUTES   MCP wait timeout in minutes (default: 30)
  --dry-run           Show what would be done without executing
  --uninstall         Remove all resources created by this script
  -h, --help          Show this help message

Credentials:
  The script requires a base64-encoded token for registry.stage.redhat.io.
  You can provide it via:
    1. --token flag
    2. STAGE_REGISTRY_TOKEN environment variable
    3. Interactive prompt at runtime

Examples:
  $(basename "$0") --email pripatil
  $(basename "$0") --email pripatil --token "MjAw..."
  STAGE_REGISTRY_TOKEN="MjAw..." $(basename "$0") --email pripatil
  $(basename "$0") --email pripatil --dry-run
  $(basename "$0") --uninstall
EOF
    exit 0
}

# --- Argument parsing ---

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --email)
                EMAIL="$2"; shift 2 ;;
            --token)
                STAGE_REGISTRY_TOKEN="$2"; shift 2 ;;
            --timeout)
                MCP_TIMEOUT="$2"; shift 2 ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --uninstall)
                UNINSTALL=true; shift ;;
            -h|--help)
                usage ;;
            *)
                error "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

# --- Collect credentials ---

collect_credentials() {
    step "0.5" "Collecting registry credentials"

    if [[ -z "$STAGE_REGISTRY_TOKEN" ]]; then
        echo ""
        info "Stage registry token required for registry.stage.redhat.io"
        info "Obtain your token: encode your service account credentials with base64"
        info "(Or set STAGE_REGISTRY_TOKEN environment variable before running)"
        echo ""
        read -rp "  Paste your base64-encoded registry token: " STAGE_REGISTRY_TOKEN
        echo ""
    fi

    if [[ -z "$STAGE_REGISTRY_TOKEN" ]]; then
        error "Registry token cannot be empty. Use --token flag or set STAGE_REGISTRY_TOKEN env var."
    fi

    if ! echo "$STAGE_REGISTRY_TOKEN" | base64 -d &>/dev/null; then
        error "Token does not appear to be valid base64. Please check and try again."
    fi

    success "Registry token accepted"
}

# --- Pre-flight checks ---

preflight_checks() {
    step "0" "Pre-flight checks"

    if ! command -v oc &>/dev/null; then
        error "'oc' CLI not found. Please install it first."
    fi
    success "oc CLI found"

    if ! command -v jq &>/dev/null; then
        error "'jq' not found. Install it with: sudo dnf install jq"
    fi
    success "jq found"

    if ! oc whoami &>/dev/null; then
        error "Not logged into an OpenShift cluster. Run 'oc login' first."
    fi
    local cluster_user
    cluster_user=$(oc whoami)
    local cluster_server
    cluster_server=$(oc whoami --show-server)
    success "Logged in as: $cluster_user @ $cluster_server"

    local ocp_version
    ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | grep -oP '^\d+\.\d+')
    if [[ ! "$ocp_version" =~ ^($SUPPORTED_OCP_VERSIONS)$ ]]; then
        error "OCP version $ocp_version is not supported. Use OCP 4.20, 4.21, or 4.22."
    fi
    success "OCP version: $ocp_version (supported)"
}

# --- Wait for MCP ---

wait_for_mcp() {
    local timeout_seconds=$((MCP_TIMEOUT * 60))
    info "Waiting for MachineConfigPools to update (timeout: ${MCP_TIMEOUT}m)..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local elapsed=$(( $(date +%s) - start_time ))
        if [[ $elapsed -ge $timeout_seconds ]]; then
            error "MCP update timed out after ${MCP_TIMEOUT} minutes"
        fi

        local updating
        updating=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updating")].status}{" "}{end}' 2>/dev/null)

        if ! echo "$updating" | grep -q "True"; then
            local degraded
            degraded=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{" "}{end}' 2>/dev/null)
            if echo "$degraded" | grep -q "True"; then
                error "MCP is in Degraded state. Check: oc get mcp"
            fi
            success "All MachineConfigPools updated successfully"
            return 0
        fi

        local remaining=$(( (timeout_seconds - elapsed) / 60 ))
        printf "\r  Waiting... (%dm elapsed, ~%dm remaining)  " $((elapsed/60)) "$remaining"
        sleep 30
    done
}

# --- Uninstall ---

do_uninstall() {
    step "1" "Uninstalling Logging 6.6 Hackathon resources"

    # --- CR Cleanup (before operator removal) ---
    info "Checking for Custom Resources that need cleanup..."
    echo ""

    local clf_list
    clf_list=$(oc get clusterlogforwarder -A --no-headers 2>/dev/null || true)
    if [[ -n "$clf_list" ]]; then
        warn "Found ClusterLogForwarder CR(s):"
        echo "$clf_list"
        echo ""
        read -rp "  Delete all ClusterLogForwarder CRs? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            oc delete clusterlogforwarder --all -A --ignore-not-found 2>/dev/null || true
            success "ClusterLogForwarder CRs deleted"
        else
            info "Skipping ClusterLogForwarder deletion"
        fi
    fi

    local loki_list
    loki_list=$(oc get lokistack -A --no-headers 2>/dev/null || true)
    if [[ -n "$loki_list" ]]; then
        warn "Found LokiStack CR(s):"
        echo "$loki_list"
        echo ""
        read -rp "  Delete all LokiStack CRs? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            oc delete lokistack --all -A --ignore-not-found 2>/dev/null || true
            info "Waiting for LokiStack resources to terminate..."
            sleep 15
            success "LokiStack CRs deleted"
        else
            info "Skipping LokiStack deletion"
        fi
    fi

    local uiplugin_list
    uiplugin_list=$(oc get uiplugin -A --no-headers 2>/dev/null || true)
    if [[ -n "$uiplugin_list" ]]; then
        warn "Found UIPlugin CR(s):"
        echo "$uiplugin_list"
        echo ""
        read -rp "  Delete all UIPlugin CRs? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            oc delete uiplugin --all -A --ignore-not-found 2>/dev/null || true
            success "UIPlugin CRs deleted"
        else
            info "Skipping UIPlugin deletion"
        fi
    fi

    echo ""

    # --- Operator removal ---
    info "Deleting Subscriptions..."
    oc delete sub cluster-logging -n openshift-logging --ignore-not-found 2>/dev/null || true
    oc delete sub loki-operator -n openshift-operators-redhat --ignore-not-found 2>/dev/null || true

    info "Deleting CSVs..."
    oc delete csv -n openshift-logging -l operators.coreos.com/cluster-logging.openshift-logging --ignore-not-found 2>/dev/null || true
    oc delete csv -n openshift-operators-redhat -l operators.coreos.com/loki-operator.openshift-operators-redhat --ignore-not-found 2>/dev/null || true

    info "Deleting OperatorGroups..."
    oc delete operatorgroup cluster-logging -n openshift-logging --ignore-not-found 2>/dev/null || true
    oc delete operatorgroup loki-operator -n openshift-operators-redhat --ignore-not-found 2>/dev/null || true

    info "Deleting CatalogSources..."
    oc delete catalogsource clo-stage -n openshift-marketplace --ignore-not-found 2>/dev/null || true
    oc delete catalogsource lo-stage -n openshift-marketplace --ignore-not-found 2>/dev/null || true

    info "Deleting ImageDigestMirrorSet..."
    oc delete imagedigestmirrorset logging-stage --ignore-not-found 2>/dev/null || true

    info "Cleaning up failed unpack jobs..."
    oc delete jobs --all -n openshift-marketplace --ignore-not-found 2>/dev/null || true

    info "Waiting for MCP to stabilize after IDMS removal..."
    sleep 10
    wait_for_mcp

    success "Uninstall complete. Pull-secret was NOT reverted (manual step if needed)."
    echo ""
    info "To remove registry.stage.redhat.io from pull-secret manually:"
    echo "  oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\\.dockerconfigjson}' | base64 -d | jq 'del(.auths[\"registry.stage.redhat.io\"])' > /tmp/clean-pull-secret.json"
    echo "  oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/clean-pull-secret.json"
}

# --- Install steps ---

step_update_pull_secret() {
    step "1" "Updating pull-secret with registry.stage.redhat.io credentials"

    local existing_auth
    existing_auth=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths["registry.stage.redhat.io"].auth // empty')

    if [[ "$existing_auth" == "$STAGE_REGISTRY_TOKEN" ]]; then
        success "Pull-secret already contains registry.stage.redhat.io (skipping)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would add registry.stage.redhat.io to pull-secret"
        return 0
    fi

    local tmp_current
    tmp_current=$(mktemp /tmp/pull-secret-current-XXXXXX.json)
    local tmp_new
    tmp_new=$(mktemp /tmp/pull-secret-new-XXXXXX.json)

    trap "rm -f $tmp_current $tmp_new" RETURN

    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$tmp_current"

    jq --arg token "$STAGE_REGISTRY_TOKEN" --arg email "${EMAIL}@redhat.com" \
        '.auths["registry.stage.redhat.io"] = {"auth": $token, "email": $email}' \
        "$tmp_current" > "$tmp_new"

    if ! python3 -m json.tool "$tmp_new" &>/dev/null; then
        error "Generated pull-secret JSON is invalid. This is a bug - please report it."
    fi

    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="$tmp_new"
    success "Pull-secret updated with registry.stage.redhat.io"

    info "Waiting for MCP to pick up pull-secret change..."
    sleep 15
    wait_for_mcp
}

step_create_catalog_sources() {
    step "2" "Creating CatalogSources"

    if oc get catalogsource clo-stage -n openshift-marketplace &>/dev/null; then
        local current_image
        current_image=$(oc get catalogsource clo-stage -n openshift-marketplace -o jsonpath='{.spec.image}')
        if [[ "$current_image" == "$CLO_CATALOG_IMAGE" ]]; then
            success "CatalogSource clo-stage already exists with correct image (skipping)"
        else
            warn "CatalogSource clo-stage exists with different image, updating..."
            if [[ "$DRY_RUN" == false ]]; then
                oc delete catalogsource clo-stage -n openshift-marketplace
            fi
        fi
    fi

    if ! oc get catalogsource clo-stage -n openshift-marketplace &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] Would create CatalogSource clo-stage"
        else
            oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: clo-stage
  namespace: openshift-marketplace
spec:
  displayName: Cluster Logging Operator Staging Catalog
  image: ${CLO_CATALOG_IMAGE}
  publisher: Team Logging
  sourceType: grpc
EOF
            success "CatalogSource clo-stage created"
        fi
    fi

    if oc get catalogsource lo-stage -n openshift-marketplace &>/dev/null; then
        local current_image
        current_image=$(oc get catalogsource lo-stage -n openshift-marketplace -o jsonpath='{.spec.image}')
        if [[ "$current_image" == "$LOKI_CATALOG_IMAGE" ]]; then
            success "CatalogSource lo-stage already exists with correct image (skipping)"
        else
            warn "CatalogSource lo-stage exists with different image, updating..."
            if [[ "$DRY_RUN" == false ]]; then
                oc delete catalogsource lo-stage -n openshift-marketplace
            fi
        fi
    fi

    if ! oc get catalogsource lo-stage -n openshift-marketplace &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            info "[DRY-RUN] Would create CatalogSource lo-stage"
        else
            oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: lo-stage
  namespace: openshift-marketplace
spec:
  displayName: Loki Operator Staging Catalog
  image: ${LOKI_CATALOG_IMAGE}
  publisher: Team Logging
  sourceType: grpc
EOF
            success "CatalogSource lo-stage created"
        fi
    fi
}

step_create_idms() {
    step "3" "Creating ImageDigestMirrorSet"

    if oc get imagedigestmirrorset logging-stage &>/dev/null; then
        success "ImageDigestMirrorSet logging-stage already exists (skipping)"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create ImageDigestMirrorSet logging-stage"
        return 0
    fi

    oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: logging-stage
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io/openshift-logging
    source: registry.redhat.io/openshift-logging
EOF
    success "ImageDigestMirrorSet logging-stage created"

    info "Waiting for MCP to apply new mirror configuration..."
    sleep 15
    wait_for_mcp
}

step_validate_catalog_sources() {
    step "4" "Validating CatalogSources are ready"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would validate CatalogSource readiness"
        return 0
    fi

    local retries=20
    local delay=15

    for source in clo-stage lo-stage; do
        info "Waiting for CatalogSource $source to become READY..."
        local attempt=0
        while [[ $attempt -lt $retries ]]; do
            local state
            state=$(oc get catalogsource "$source" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
            if [[ "$state" == "READY" ]]; then
                success "CatalogSource $source is READY"
                break
            fi
            attempt=$((attempt + 1))
            if [[ $attempt -ge $retries ]]; then
                error "CatalogSource $source did not become READY within $((retries * delay))s"
            fi
            sleep "$delay"
        done
    done
}

step_cleanup_stale_jobs() {
    step "5" "Cleaning up stale unpack jobs (if any)"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would clean up failed jobs in openshift-marketplace"
        return 0
    fi

    local failed_jobs
    failed_jobs=$(oc get jobs -n openshift-marketplace -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

    if [[ -n "$failed_jobs" ]]; then
        info "Removing failed unpack jobs..."
        echo "$failed_jobs" | while read -r job; do
            [[ -n "$job" ]] && oc delete job "$job" -n openshift-marketplace --ignore-not-found 2>/dev/null
        done
        success "Stale jobs cleaned up"
    else
        success "No stale jobs found"
    fi
}

step_create_logging_operator() {
    step "6" "Installing Cluster Logging Operator"

    oc create namespace openshift-logging --dry-run=client -o yaml | oc apply -f - 2>/dev/null

    local existing_ogs
    existing_ogs=$(oc get operatorgroup -n openshift-logging --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo "")

    if [[ -n "$existing_ogs" ]]; then
        local other_ogs
        other_ogs=$(echo "$existing_ogs" | grep -v "^cluster-logging$" || true)
        if [[ -n "$other_ogs" ]]; then
            warn "Found pre-existing OperatorGroup(s) in openshift-logging namespace:"
            echo "$other_ogs" | while read -r og; do
                warn "  Removing: $og"
                if [[ "$DRY_RUN" == false ]]; then
                    oc delete operatorgroup "$og" -n openshift-logging --ignore-not-found 2>/dev/null || true
                fi
            done
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create OperatorGroup and Subscription for cluster-logging"
        return 0
    fi

    if ! oc get operatorgroup cluster-logging -n openshift-logging &>/dev/null; then
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  upgradeStrategy: Default
EOF
        success "OperatorGroup cluster-logging created"
    else
        success "OperatorGroup cluster-logging already exists (skipping)"
    fi

    if oc get sub cluster-logging -n openshift-logging &>/dev/null; then
        success "Subscription cluster-logging already exists (skipping)"
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
  labels:
    operators.coreos.com/cluster-logging.openshift-logging: ''
spec:
  channel: stable-6.6
  installPlanApproval: Automatic
  name: cluster-logging
  source: clo-stage
  sourceNamespace: openshift-marketplace
  startingCSV: cluster-logging.v6.6.0
EOF
        success "Subscription cluster-logging created"
    fi
}

step_create_loki_operator() {
    step "7" "Installing Loki Operator"

    oc create namespace openshift-operators-redhat --dry-run=client -o yaml | oc apply -f - 2>/dev/null

    local existing_ogs
    existing_ogs=$(oc get operatorgroup -n openshift-operators-redhat --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || echo "")

    if [[ -n "$existing_ogs" ]]; then
        local other_ogs
        other_ogs=$(echo "$existing_ogs" | grep -v "^loki-operator$" || true)
        if [[ -n "$other_ogs" ]]; then
            warn "Found pre-existing OperatorGroup(s) in openshift-operators-redhat namespace:"
            echo "$other_ogs" | while read -r og; do
                warn "  Removing: $og"
                if [[ "$DRY_RUN" == false ]]; then
                    oc delete operatorgroup "$og" -n openshift-operators-redhat --ignore-not-found 2>/dev/null || true
                fi
            done
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would create OperatorGroup and Subscription for loki-operator"
        return 0
    fi

    if ! oc get operatorgroup loki-operator -n openshift-operators-redhat &>/dev/null; then
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  upgradeStrategy: Default
EOF
        success "OperatorGroup loki-operator created"
    else
        success "OperatorGroup loki-operator already exists (skipping)"
    fi

    if oc get sub loki-operator -n openshift-operators-redhat &>/dev/null; then
        success "Subscription loki-operator already exists (skipping)"
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
  labels:
    operators.coreos.com/loki-operator.openshift-operators-redhat: ''
spec:
  channel: stable-6.6
  installPlanApproval: Automatic
  name: loki-operator
  source: lo-stage
  sourceNamespace: openshift-marketplace
  startingCSV: loki-operator.v6.6.0
EOF
        success "Subscription loki-operator created"
    fi
}

step_wait_for_operators() {
    step "8" "Waiting for operators to install"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would wait for CSV phase=Succeeded"
        return 0
    fi

    local retries=40
    local delay=15

    info "Waiting for Cluster Logging Operator CSV..."
    local attempt=0
    while [[ $attempt -lt $retries ]]; do
        local phase
        phase=$(oc get csv cluster-logging.v6.6.0 -n openshift-logging -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Succeeded" ]]; then
            success "Cluster Logging Operator v6.6.0 installed successfully"
            break
        elif [[ "$phase" == "Failed" ]]; then
            error "Cluster Logging Operator CSV failed. Check: oc get csv -n openshift-logging"
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -ge $retries ]]; then
            error "Cluster Logging Operator did not install within $((retries * delay))s. Check: oc get sub,csv,installplan -n openshift-logging"
        fi
        printf "\r  Phase: %-20s (attempt %d/%d)" "${phase:-Pending}" "$attempt" "$retries"
        sleep "$delay"
    done
    echo ""

    info "Waiting for Loki Operator CSV..."
    attempt=0
    while [[ $attempt -lt $retries ]]; do
        local phase
        phase=$(oc get csv loki-operator.v6.6.0 -n openshift-operators-redhat -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Succeeded" ]]; then
            success "Loki Operator v6.6.0 installed successfully"
            break
        elif [[ "$phase" == "Failed" ]]; then
            error "Loki Operator CSV failed. Check: oc get csv -n openshift-operators-redhat"
        fi
        attempt=$((attempt + 1))
        if [[ $attempt -ge $retries ]]; then
            error "Loki Operator did not install within $((retries * delay))s. Check: oc get sub,csv,installplan -n openshift-operators-redhat"
        fi
        printf "\r  Phase: %-20s (attempt %d/%d)" "${phase:-Pending}" "$attempt" "$retries"
        sleep "$delay"
    done
    echo ""
}

step_final_validation() {
    step "9" "Final Validation"

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY-RUN] Would validate final state"
        return 0
    fi

    echo ""
    info "=== Installation Summary ==="
    echo ""

    echo "  Cluster Logging Operator:"
    local clo_phase
    clo_phase=$(oc get csv cluster-logging.v6.6.0 -n openshift-logging -o jsonpath='{.status.phase}' 2>/dev/null || echo "Not Found")
    echo "    CSV: cluster-logging.v6.6.0  Status: $clo_phase"
    echo ""

    echo "  Loki Operator:"
    local loki_phase
    loki_phase=$(oc get csv loki-operator.v6.6.0 -n openshift-operators-redhat -o jsonpath='{.status.phase}' 2>/dev/null || echo "Not Found")
    echo "    CSV: loki-operator.v6.6.0    Status: $loki_phase"
    echo ""

    echo "  CatalogSources:"
    local clo_cs_state
    clo_cs_state=$(oc get catalogsource clo-stage -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "Unknown")
    local lo_cs_state
    lo_cs_state=$(oc get catalogsource lo-stage -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "Unknown")
    echo "    clo-stage: $clo_cs_state"
    echo "    lo-stage:  $lo_cs_state"
    echo ""

    if [[ "$clo_phase" == "Succeeded" && "$loki_phase" == "Succeeded" ]]; then
        echo -e "  ${GREEN}All operators installed successfully!${NC}"
    else
        echo -e "  ${YELLOW}Some operators may not be fully ready. Check with:${NC}"
        echo "    oc get csv -n openshift-logging"
        echo "    oc get csv -n openshift-operators-redhat"
    fi

    echo ""
    info "Log file: $LOG_FILE"
}

# --- Main ---

main() {
    parse_args "$@"

    LOG_FILE="/tmp/logging-hackathon-install-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE"

    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Logging 6.6 Hackathon Installer v${SCRIPT_VERSION}          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ "$UNINSTALL" == true ]]; then
        preflight_checks
        do_uninstall
        exit 0
    fi

    if [[ -z "$EMAIL" ]]; then
        read -rp "Enter your Red Hat email prefix (e.g., pripatil): " EMAIL
        if [[ -z "$EMAIL" ]]; then
            error "Email is required. Use --email flag or enter when prompted."
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        warn "DRY-RUN mode: No changes will be made"
    fi

    info "Email: ${EMAIL}@redhat.com"
    info "MCP timeout: ${MCP_TIMEOUT} minutes"
    info "Log file: $LOG_FILE"
    echo ""

    preflight_checks
    collect_credentials
    step_update_pull_secret
    step_create_catalog_sources
    step_create_idms
    step_validate_catalog_sources
    step_cleanup_stale_jobs
    step_create_logging_operator
    step_create_loki_operator
    step_wait_for_operators
    step_final_validation
}

main "$@"
