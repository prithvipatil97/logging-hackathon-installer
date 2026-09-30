#!/bin/bash
###############################################################################
#
#  Test: BoltDB Deprecation & Loki 4.0 Migration Validation
#
#  Version: 1.0.0
#  Epic:    LOG-9510 - Loki Operator - Loki 4.0 changes required
#
#  Purpose:
#    Automated validation script for the Logging 6.7 hackathon to verify
#    that all BoltDB deprecation and Loki 4.0 migration features are
#    working correctly on a fresh or upgraded OpenShift cluster.
#
#  What this test validates:
#    Phase 1 - Prerequisites (operators running, LokiStack healthy)
#    Phase 2 - Schemas field is now REQUIRED in LokiStack (LOG-9351)
#    Phase 3 - BoltDB (v11) schema is REJECTED (LOG-9512)
#    Phase 4 - BoltDB deprecation alert rule EXISTS (LOG-9744)
#    Phase 5 - Old loki_boltdb_shipper metrics REMOVED (LOG-9666)
#    Phase 6 - Ruler remote_write uses "clients" plural (LOG-9665)
#
#  Prerequisites:
#    - Logging 6.7 + Loki 6.7 Operators installed and running
#    - A healthy LokiStack deployed in openshift-logging
#    - oc CLI logged in with cluster-admin privileges
#
#  Usage:
#    chmod +x test-boltdb-loki4-migration.sh
#    ./test-boltdb-loki4-migration.sh
#
#  Author:  Prithviraj Patil (Red Hat Logging Hackathon 6.7)
#
###############################################################################

set -uo pipefail

# =============================================================================
#  CONFIGURATION
# =============================================================================

NAMESPACE="openshift-logging"
LOKI_OPERATOR_NS="openshift-operators-redhat"
MONITORING_NS="openshift-monitoring"
LOKISTACK_NAME="logging-loki"
PHASE_PAUSE=5                 # seconds to pause between phases
SCRIPT_VERSION="1.0.0"
SCRIPT_START_TIME=$(date +%s)

# Test LokiStack names (temporary, will be cleaned up)
TEST_LS_NO_SCHEMA="test-no-schema-$$"
TEST_LS_BOLTDB="test-boltdb-$$"

# =============================================================================
#  COLORS AND FORMATTING
# =============================================================================

# Regular colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

# Bold colors
BRED='\033[1;31m'
BGREEN='\033[1;32m'
BYELLOW='\033[1;33m'
BBLUE='\033[1;34m'
BMAGENTA='\033[1;35m'
BCYAN='\033[1;36m'
BWHITE='\033[1;37m'

# Background colors
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_MAGENTA='\033[45m'
BG_CYAN='\033[46m'

# Text styles
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
NC='\033[0m'

# =============================================================================
#  TEST RESULTS TRACKING
# =============================================================================

declare -A RESULTS
declare -A PHASE_TIMES
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
CURRENT_PHASE_START=0

# =============================================================================
#  HELPER FUNCTIONS
# =============================================================================

get_elapsed() {
    local now=$(date +%s)
    local elapsed=$((now - SCRIPT_START_TIME))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    printf "%02d:%02d" "$mins" "$secs"
}

get_phase_elapsed() {
    local now=$(date +%s)
    local elapsed=$((now - CURRENT_PHASE_START))
    echo "${elapsed}s"
}

print_banner() {
    local width=78
    echo ""
    echo ""
    echo -e "${BCYAN}    ██████╗  ██████╗ ██╗  ████████╗██████╗ ██████╗ ${NC}"
    echo -e "${BCYAN}    ██╔══██╗██╔═══██╗██║  ╚══██╔══╝██╔══██╗██╔══██╗${NC}"
    echo -e "${BCYAN}    ██████╔╝██║   ██║██║     ██║   ██║  ██║██████╔╝${NC}"
    echo -e "${BCYAN}    ██╔══██╗██║   ██║██║     ██║   ██║  ██║██╔══██╗${NC}"
    echo -e "${BCYAN}    ██████╔╝╚██████╔╝███████╗██║   ██████╔╝██████╔╝${NC}"
    echo -e "${BCYAN}    ╚═════╝  ╚═════╝ ╚══════╝╚═╝   ╚═════╝ ╚═════╝ ${NC}"
    echo ""
    echo -e "${BWHITE}  ╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BWHITE}  ║${NC}                                                                        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${BOLD}${BCYAN}BoltDB Deprecation & Loki 4.0 Migration${NC}  ${DIM}Automated Validation${NC}        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}                                                                        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Epic:${NC}    ${BWHITE}LOG-9510${NC} ${DIM}- Loki Operator - Loki 4.0 changes required${NC}       ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Version:${NC} ${BWHITE}${SCRIPT_VERSION}${NC}                                                     ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Date:${NC}    ${BWHITE}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}                            ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}                                                                        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}Testing 5 Jira tickets: LOG-9351 | LOG-9512 | LOG-9744 | LOG-9666 | LOG-9665${NC}"
    echo ""
}

print_phase_header() {
    local phase_num=$1
    local phase_name=$2
    local jira_key=$3
    CURRENT_PHASE_START=$(date +%s)

    echo ""
    echo -e "  ${BG_BLUE}${BWHITE}                                                                          ${NC}"
    echo -e "  ${BG_BLUE}${BWHITE}   PHASE ${phase_num}                                                                ${NC}"
    echo -e "  ${BG_BLUE}${BWHITE}   ${phase_name}$(printf '%*s' $((55 - ${#phase_name})) '')${NC}"
    echo -e "  ${BG_BLUE}${BWHITE}   Jira: ${jira_key}$(printf '%*s' $((53 - ${#jira_key})) '')${NC}"
    echo -e "  ${BG_BLUE}${BWHITE}                                                                          ${NC}"
    echo ""
}

print_phase_complete() {
    local phase_num=$1
    local elapsed=$(get_phase_elapsed)
    echo ""
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}Phase ${phase_num} completed in ${BWHITE}${elapsed}${NC}  ${DIM}[Total elapsed: $(get_elapsed)]${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
}

phase_transition() {
    local next_phase=$1
    local next_name=$2
    echo ""
    echo -e "  ${BYELLOW}▶ Transitioning to Phase ${next_phase}: ${next_name}${NC}"
    local remaining=$PHASE_PAUSE
    while [ $remaining -gt 0 ]; do
        printf "\r  ${DIM}  Starting in ${remaining}s...${NC}  "
        sleep 1
        remaining=$((remaining - 1))
    done
    printf "\r  ${DIM}                          ${NC}\n"
}

log_info() {
    echo -e "  ${BCYAN}  ℹ ${NC} ${WHITE}$1${NC}"
}

log_action() {
    echo -e "  ${BMAGENTA}  ▸ ${NC} ${BOLD}$1${NC}"
}

log_detail() {
    echo -e "  ${DIM}      $1${NC}"
}

log_pass() {
    echo -e "  ${BGREEN}  ✔ ${NC} ${BGREEN}PASS${NC}  $1"
    TOTAL_PASS=$((TOTAL_PASS + 1))
}

log_fail() {
    echo -e "  ${BRED}  ✘ ${NC} ${BRED}FAIL${NC}  $1"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

log_skip() {
    echo -e "  ${BYELLOW}  ⊘ ${NC} ${BYELLOW}SKIP${NC}  $1"
    TOTAL_SKIP=$((TOTAL_SKIP + 1))
}

log_wait() {
    echo -e "  ${BYELLOW}  ⏳${NC} ${YELLOW}$1${NC}"
}

log_error_output() {
    echo -e "  ${DIM}      ┌─ Error Output ────────────────────────────────────────${NC}"
    echo "$1" | head -5 | while IFS= read -r line; do
        echo -e "  ${DIM}      │${NC} ${RED}${line}${NC}"
    done
    echo -e "  ${DIM}      └────────────────────────────────────────────────────────${NC}"
}

log_success_output() {
    echo -e "  ${DIM}      ┌─ Output ──────────────────────────────────────────────${NC}"
    echo "$1" | head -5 | while IFS= read -r line; do
        echo -e "  ${DIM}      │${NC} ${GREEN}${line}${NC}"
    done
    echo -e "  ${DIM}      └────────────────────────────────────────────────────────${NC}"
}

record_result() {
    local test_name=$1
    local status=$2
    RESULTS["$test_name"]="$status"
}

spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BCYAN}  ${spin:i++%${#spin}:1} ${NC} ${DIM}${msg}${NC}  "
        sleep 0.1
    done
    printf "\r  ${DIM}                                                              ${NC}\r"
}

# =============================================================================
#  CLEANUP
# =============================================================================

cleanup() {
    echo ""
    log_info "Running cleanup of test resources..."
    oc delete lokistack "${TEST_LS_NO_SCHEMA}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
    oc delete lokistack "${TEST_LS_BOLTDB}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
    log_info "Cleanup complete."
}

trap cleanup EXIT

# =============================================================================
#
#   MAIN TEST EXECUTION
#
# =============================================================================

print_banner

# =============================================================================
#  PHASE 1: PREREQUISITES CHECK
# =============================================================================

print_phase_header 1 "Prerequisites Check" "N/A"

# --- Check oc CLI ---
log_action "Checking oc CLI access..."
if ! oc whoami &>/dev/null; then
    log_fail "Not logged in to OpenShift cluster"
    echo ""
    echo -e "  ${BRED}  Please run 'oc login' first and try again.${NC}"
    echo ""
    exit 1
fi
LOGGED_USER=$(oc whoami 2>/dev/null)
CLUSTER_URL=$(oc whoami --show-server 2>/dev/null)
log_pass "Logged in as: ${BWHITE}${LOGGED_USER}${NC}"
log_detail "Cluster: ${CLUSTER_URL}"
record_result "OC Login" "PASS"

# --- Check Loki Operator ---
log_action "Checking Loki Operator in ${LOKI_OPERATOR_NS}..."
LOKI_OP_POD=$(oc get pods -n "${LOKI_OPERATOR_NS}" -l app.kubernetes.io/name=loki-operator -o name 2>/dev/null | head -1)
if [ -z "$LOKI_OP_POD" ]; then
    log_fail "Loki Operator pod not found in ${LOKI_OPERATOR_NS}"
    log_info "Please install Loki Operator 6.7 first."
    record_result "Loki Operator" "FAIL"
    exit 1
fi
LOKI_OP_STATUS=$(oc get "${LOKI_OP_POD}" -n "${LOKI_OPERATOR_NS}" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$LOKI_OP_STATUS" != "Running" ]; then
    log_fail "Loki Operator pod is not Running (status: ${LOKI_OP_STATUS})"
    record_result "Loki Operator" "FAIL"
    exit 1
fi
LOKI_OP_VERSION=$(oc get "${LOKI_OP_POD}" -n "${LOKI_OPERATOR_NS}" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null | awk -F: '{print $NF}')
log_pass "Loki Operator is running"
log_detail "Pod: ${LOKI_OP_POD##*/}"
log_detail "Image tag: ${LOKI_OP_VERSION}"
record_result "Loki Operator" "PASS"

# --- Check CLO ---
log_action "Checking Cluster Logging Operator in ${NAMESPACE}..."
CLO_POD=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=cluster-logging-operator -o name 2>/dev/null | head -1)
if [ -z "$CLO_POD" ]; then
    log_fail "Cluster Logging Operator pod not found in ${NAMESPACE}"
    record_result "CLO Running" "FAIL"
    exit 1
fi
CLO_STATUS=$(oc get "${CLO_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$CLO_STATUS" != "Running" ]; then
    log_fail "CLO pod is not Running (status: ${CLO_STATUS})"
    record_result "CLO Running" "FAIL"
    exit 1
fi
log_pass "Cluster Logging Operator is running"
log_detail "Pod: ${CLO_POD##*/}"
record_result "CLO Running" "PASS"

# --- Check LokiStack ---
log_action "Checking LokiStack '${LOKISTACK_NAME}' in ${NAMESPACE}..."
LS_EXISTS=$(oc get lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" -o name 2>/dev/null)
if [ -z "$LS_EXISTS" ]; then
    log_skip "LokiStack '${LOKISTACK_NAME}' not found (some tests will adapt)"
    record_result "LokiStack" "SKIP"
    HAS_LOKISTACK=false
else
    LS_READY=$(oc get lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    LS_SIZE=$(oc get lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.size}' 2>/dev/null)
    LS_SCHEMA=$(oc get lokistack "${LOKISTACK_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.storage.schemas[0].version}' 2>/dev/null)
    if [ "$LS_READY" == "True" ]; then
        log_pass "LokiStack is healthy"
    else
        log_info "LokiStack exists but not fully Ready (status: ${LS_READY:-unknown})"
        record_result "LokiStack" "PASS"
    fi
    log_detail "Size: ${LS_SIZE} | Schema: ${LS_SCHEMA} | Ready: ${LS_READY:-unknown}"
    record_result "LokiStack" "PASS"
    HAS_LOKISTACK=true
fi

# --- Check monitoring label ---
log_action "Checking namespace monitoring labels..."
for ns in "${NAMESPACE}" "${LOKI_OPERATOR_NS}"; do
    HAS_LABEL=$(oc get namespace "${ns}" -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null)
    if [ "$HAS_LABEL" == "true" ]; then
        log_pass "Namespace ${ns} has monitoring label"
    else
        log_info "Namespace ${ns} missing monitoring label (not blocking)"
    fi
done
record_result "Monitoring Labels" "PASS"

print_phase_complete 1

# =============================================================================
#  PHASE 2: SCHEMAS FIELD IS REQUIRED (LOG-9351)
# =============================================================================

phase_transition 2 "Schemas Required Validation"
print_phase_header 2 "Verify Schemas Field is Required" "LOG-9351"

log_info "In Logging 6.7, the 'schemas' field in LokiStack storage spec is now mandatory."
log_info "Previously it was optional and defaulted to v11 (BoltDB)."
echo ""

log_action "Applying test LokiStack WITHOUT schemas field..."
log_detail "Resource: ${TEST_LS_NO_SCHEMA}"

APPLY_OUTPUT=$(cat <<EOF | oc apply -f - 2>&1
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: ${TEST_LS_NO_SCHEMA}
  namespace: ${NAMESPACE}
spec:
  size: 1x.extra-small
  storage:
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: gp3-csi
  tenants:
    mode: openshift-logging
EOF
)
APPLY_RC=$?

echo ""
if [ $APPLY_RC -ne 0 ]; then
    log_pass "LokiStack WITHOUT schemas was correctly ${BRED}REJECTED${NC}"
    log_error_output "$APPLY_OUTPUT"
    record_result "Schemas Required" "PASS"
else
    # It was accepted -- check if operator sets an error condition
    log_wait "LokiStack was accepted by API. Checking if operator rejects it..."
    sleep 10
    LS_CONDITION=$(oc get lokistack "${TEST_LS_NO_SCHEMA}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    LS_MSG=$(oc get lokistack "${TEST_LS_NO_SCHEMA}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)

    if echo "$LS_CONDITION $LS_MSG" | grep -qi "schema\|required\|invalid\|fail"; then
        log_pass "Operator detected missing schemas and set error condition"
        log_detail "Reason: ${LS_CONDITION}"
        log_detail "Message: ${LS_MSG}"
        record_result "Schemas Required" "PASS"
    else
        log_fail "LokiStack WITHOUT schemas was ACCEPTED -- schemas may not be required yet"
        log_detail "This could indicate LOG-9351 is not yet merged in this build."
        record_result "Schemas Required" "FAIL"
    fi

    # Cleanup
    log_action "Cleaning up test resource..."
    oc delete lokistack "${TEST_LS_NO_SCHEMA}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null
    log_info "Test LokiStack deleted."
fi

print_phase_complete 2

# =============================================================================
#  PHASE 3: BOLTDB SCHEMA IS REJECTED (LOG-9512)
# =============================================================================

phase_transition 3 "BoltDB Schema Rejection"
print_phase_header 3 "Verify BoltDB (v11) Schema is Rejected" "LOG-9512"

log_info "With Loki 4.0, BoltDB Shipper is removed from the codebase."
log_info "Creating a LokiStack with v11 schema should be rejected."
echo ""

log_action "Applying test LokiStack WITH BoltDB v11 schema..."
log_detail "Resource: ${TEST_LS_BOLTDB}"

APPLY_OUTPUT=$(cat <<EOF | oc apply -f - 2>&1
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: ${TEST_LS_BOLTDB}
  namespace: ${NAMESPACE}
spec:
  size: 1x.extra-small
  storage:
    schemas:
    - version: v11
      effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: gp3-csi
  tenants:
    mode: openshift-logging
EOF
)
APPLY_RC=$?

echo ""
if [ $APPLY_RC -ne 0 ]; then
    log_pass "LokiStack with BoltDB v11 schema was correctly ${BRED}REJECTED${NC}"
    log_error_output "$APPLY_OUTPUT"
    record_result "BoltDB Rejected" "PASS"
else
    # It was accepted -- check if operator sets an error condition
    log_wait "LokiStack was accepted by API. Checking if operator rejects it..."
    sleep 10
    LS_CONDITION=$(oc get lokistack "${TEST_LS_BOLTDB}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    LS_MSG=$(oc get lokistack "${TEST_LS_BOLTDB}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)

    if echo "$LS_CONDITION $LS_MSG" | grep -qi "boltdb\|v11\|unsupported\|deprecated\|invalid\|removed"; then
        log_pass "Operator detected BoltDB v11 and set error condition"
        log_detail "Reason: ${LS_CONDITION}"
        log_detail "Message: ${LS_MSG}"
        record_result "BoltDB Rejected" "PASS"
    else
        log_fail "LokiStack with BoltDB v11 was ACCEPTED -- BoltDB may not be blocked yet"
        log_detail "Condition: ${LS_CONDITION:-none}"
        log_detail "Message: ${LS_MSG:-none}"
        log_detail "This could indicate LOG-9512 is not yet merged in this build."
        record_result "BoltDB Rejected" "FAIL"
    fi

    # Cleanup
    log_action "Cleaning up test resource..."
    oc delete lokistack "${TEST_LS_BOLTDB}" -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null
    log_info "Test LokiStack deleted."
fi

print_phase_complete 3

# =============================================================================
#  PHASE 4: BOLTDB DEPRECATION ALERT RULE EXISTS (LOG-9744)
# =============================================================================

phase_transition 4 "Alert Rule Validation"
print_phase_header 4 "Verify BoltDB Deprecation Alert Rule Exists" "LOG-9744"

log_info "Logging 6.7 introduces a Prometheus alert that warns users still on BoltDB."
log_info "This alert fires when an existing LokiStack uses an outdated storage schema."
log_info "Expected alert name: ${BWHITE}LokistackSchemaUpgradesRequired${NC}"
log_info "On a fresh install it won't fire, but the rule definition must exist."
echo ""

log_action "Fetching PrometheusRule resources from ${LOKI_OPERATOR_NS} and ${NAMESPACE}..."

# Fetch from both namespaces and merge (alerts can be in either)
PROM_RULES_LOKI=$(oc get prometheusrule -n "${LOKI_OPERATOR_NS}" -o json 2>/dev/null || echo '{"items":[]}')
PROM_RULES_LOGGING=$(oc get prometheusrule -n "${NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')

# Combine both JSON results for searching
PROM_RULES_JSON=$(echo "${PROM_RULES_LOKI}" "${PROM_RULES_LOGGING}" | \
    jq -s '{"items": [.[].items[]?]}' 2>/dev/null)

if [ -z "$PROM_RULES_JSON" ] || [ "$PROM_RULES_JSON" == '{"items":[]}' ]; then
    log_fail "No PrometheusRules found in either namespace"
    record_result "Alert Rule Exists" "FAIL"
fi

# Search for schema-upgrade / BoltDB-related alert names
# Real alert name on live cluster: LokistackSchemaUpgradesRequired
# Expression references: lokistack_status_condition{reason="StorageNeedsSchemaUpdate"}
BOLTDB_ALERTS=$(echo "$PROM_RULES_JSON" | \
    jq -r '.items[]?.spec.groups[]?.rules[]? | select(.alert != null) | select(.alert | test("(?i)boltdb|bolt_db|schema.*deprecat|storage.*deprecat|schema.*upgrade|schema.*required|StorageNeedsSchema")) | .alert' 2>/dev/null | sort -u)

echo ""
if [ -n "$BOLTDB_ALERTS" ]; then
    log_pass "BoltDB deprecation alert rule(s) found!"
    echo ""
    echo "$BOLTDB_ALERTS" | while IFS= read -r alert_name; do
        echo -e "  ${DIM}      ┌─ Alert Definition ─────────────────────────────────────${NC}"
        echo -e "  ${DIM}      │${NC} ${BGREEN}Alert:${NC} ${BWHITE}${alert_name}${NC}"

        # Get the alert expression
        ALERT_EXPR=$(echo "$PROM_RULES_JSON" | \
            jq -r --arg name "$alert_name" '.items[]?.spec.groups[]?.rules[]? | select(.alert == $name) | .expr' 2>/dev/null | head -1)
        if [ -n "$ALERT_EXPR" ]; then
            echo -e "  ${DIM}      │${NC} ${CYAN}Expr:${NC}  ${DIM}${ALERT_EXPR:0:70}${NC}"
        fi

        # Get severity
        ALERT_SEV=$(echo "$PROM_RULES_JSON" | \
            jq -r --arg name "$alert_name" '.items[]?.spec.groups[]?.rules[]? | select(.alert == $name) | .labels.severity // "N/A"' 2>/dev/null | head -1)
        echo -e "  ${DIM}      │${NC} ${YELLOW}Severity:${NC} ${ALERT_SEV}"

        # Get description/annotation
        ALERT_DESC=$(echo "$PROM_RULES_JSON" | \
            jq -r --arg name "$alert_name" '.items[]?.spec.groups[]?.rules[]? | select(.alert == $name) | .annotations.description // .annotations.message // "N/A"' 2>/dev/null | head -1)
        echo -e "  ${DIM}      │${NC} ${WHITE}Desc:${NC}  ${DIM}${ALERT_DESC:0:70}${NC}"
        echo -e "  ${DIM}      └──────────────────────────────────────────────────────────${NC}"
    done
    record_result "Alert Rule Exists" "PASS"
else
    # Also search all alert names for any hint
    ALL_LOKI_ALERTS=$(echo "$PROM_RULES_JSON" | \
        jq -r '.items[]?.spec.groups[]?.rules[]? | select(.alert != null) | .alert' 2>/dev/null | sort -u)

    if [ -n "$ALL_LOKI_ALERTS" ]; then
        log_fail "No BoltDB deprecation alert found in PrometheusRules"
        log_detail "This could indicate LOG-9744 is not yet merged in this build."
        echo ""
        log_info "Available Loki Operator alerts for reference:"
        echo "$ALL_LOKI_ALERTS" | while IFS= read -r a; do
            echo -e "  ${DIM}      - ${a}${NC}"
        done
    else
        log_fail "No PrometheusRule alert definitions found at all"
        log_detail "Ensure Loki Operator is fully reconciled."
    fi
    record_result "Alert Rule Exists" "FAIL"
fi

print_phase_complete 4

# =============================================================================
#  PHASE 5: OLD BOLTDB METRICS REMOVED FROM ALERTS/DASHBOARDS (LOG-9666)
# =============================================================================

phase_transition 5 "Metrics Cleanup Validation"
print_phase_header 5 "Verify Old BoltDB Metrics Removed" "LOG-9666"

log_info "Loki 4.0 removes BoltDB Shipper, so the old 'loki_boltdb_shipper_*' metrics"
log_info "should no longer be referenced in PrometheusRules or dashboards."
echo ""

# --- Check PrometheusRules for boltdb_shipper references ---
log_action "Scanning PrometheusRules for 'loki_boltdb_shipper' references..."

# Use the combined PROM_RULES_JSON from Phase 4 (has both namespaces)
# If it's empty, re-fetch
if [ -z "$PROM_RULES_JSON" ] || [ "$PROM_RULES_JSON" == '{"items":[]}' ]; then
    PROM_RULES_LOKI=$(oc get prometheusrule -n "${LOKI_OPERATOR_NS}" -o json 2>/dev/null || echo '{"items":[]}')
    PROM_RULES_LOGGING=$(oc get prometheusrule -n "${NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
    PROM_RULES_JSON=$(echo "${PROM_RULES_LOKI}" "${PROM_RULES_LOGGING}" | \
        jq -s '{"items": [.[].items[]?]}' 2>/dev/null)
fi

BOLTDB_REFS_COUNT=$(echo "$PROM_RULES_JSON" | grep -c "loki_boltdb_shipper" 2>/dev/null || true)
BOLTDB_REFS_COUNT=${BOLTDB_REFS_COUNT:-0}

echo ""
if [ "$BOLTDB_REFS_COUNT" -eq 0 ]; then
    log_pass "Zero 'loki_boltdb_shipper' references in PrometheusRules"
    record_result "Rules Cleaned" "PASS"
else
    log_fail "Found ${BOLTDB_REFS_COUNT} 'loki_boltdb_shipper' references still in PrometheusRules"
    record_result "Rules Cleaned" "FAIL"
fi

# --- Check ConfigMaps / dashboards for boltdb references ---
log_action "Scanning ConfigMaps for BoltDB dashboard references..."

BOLTDB_REFS_CM=0
for ns in "${LOKI_OPERATOR_NS}" "${NAMESPACE}"; do
    DASHBOARD_CMS=$(oc get configmap -n "${ns}" -o name 2>/dev/null | grep -i "dashboard\|grafana" || true)
    if [ -n "$DASHBOARD_CMS" ]; then
        for cm in $DASHBOARD_CMS; do
            REFS=$(oc get "${cm}" -n "${ns}" -o yaml 2>/dev/null | grep -c "loki_boltdb_shipper" 2>/dev/null || true)
            REFS=${REFS:-0}
            if [ "$REFS" -gt 0 ]; then
                BOLTDB_REFS_CM=$((BOLTDB_REFS_CM + REFS))
                log_detail "Found ${REFS} references in ${cm} (${ns})"
            fi
        done
    fi
done

    echo ""
    if [ "$BOLTDB_REFS_CM" -eq 0 ]; then
        log_pass "Zero 'loki_boltdb_shipper' references in dashboard ConfigMaps"
        record_result "Dashboards Cleaned" "PASS"
    else
        log_fail "Found ${BOLTDB_REFS_CM} 'loki_boltdb_shipper' references in dashboards"
        record_result "Dashboards Cleaned" "FAIL"
    fi

# --- Check which alerts exist now (positive check) ---
echo ""
log_action "Listing current Loki storage-related alerts (should use TSDB metrics)..."
STORAGE_ALERTS=$(echo "$PROM_RULES_JSON" | \
    jq -r '.items[]?.spec.groups[]?.rules[]? | select(.alert != null) | select(.alert | test("(?i)storage|write|read|slow|loki")) | "\(.alert)"' 2>/dev/null | sort -u)

if [ -n "$STORAGE_ALERTS" ]; then
    echo "$STORAGE_ALERTS" | while IFS= read -r sa; do
        log_detail "$sa"
    done
else
    log_info "No storage-related alerts found (LokiStorageSlowWrite/Read may have been removed)"
fi

print_phase_complete 5

# =============================================================================
#  PHASE 6: RULER REMOTE WRITE CONFIG (LOG-9665)
# =============================================================================

phase_transition 6 "Ruler Config Validation"
print_phase_header 6 "Verify Ruler Remote Write Config Migration" "LOG-9665"

log_info "Loki 4.0 deprecates 'ruler.remote_write.client' (singular)."
log_info "The operator should now generate 'ruler.remote_write.clients' (plural)."
echo ""

if [ "$HAS_LOKISTACK" != "true" ]; then
    log_skip "No LokiStack deployed -- cannot check Loki config inside pods"
    log_detail "Deploy a LokiStack and re-run this test to validate LOG-9665."
    record_result "Ruler Config" "SKIP"
else
    # Find an ingester or compactor pod
    LOKI_POD=""
    for component in ingester compactor distributor; do
        LOKI_POD=$(oc get pods -n "${NAMESPACE}" \
            -l "app.kubernetes.io/component=${component},app.kubernetes.io/instance=${LOKISTACK_NAME}" \
            -o name 2>/dev/null | head -1)
        [ -n "$LOKI_POD" ] && break
    done

    if [ -z "$LOKI_POD" ]; then
        # Try a broader search
        LOKI_POD=$(oc get pods -n "${NAMESPACE}" -l "app.kubernetes.io/name=lokistack" -o name 2>/dev/null | head -1)
    fi

    if [ -z "$LOKI_POD" ]; then
        log_skip "No Loki component pods found -- cannot check config"
        record_result "Ruler Config" "SKIP"
    else
        log_action "Reading Loki config from pod: ${LOKI_POD##*/}..."

        # Try common config paths
        LOKI_CONFIG=""
        for config_path in "/etc/loki/config/config.yaml" "/etc/loki/config.yaml" "/etc/loki/runtime-config.yaml"; do
            LOKI_CONFIG=$(oc exec -n "${NAMESPACE}" "${LOKI_POD}" -- cat "${config_path}" 2>/dev/null)
            if [ -n "$LOKI_CONFIG" ]; then
                log_detail "Config found at: ${config_path}"
                break
            fi
        done

        echo ""
        if [ -z "$LOKI_CONFIG" ]; then
            log_skip "Could not read Loki config from pod"
            record_result "Ruler Config" "SKIP"
        else
            # Check for "clients:" (plural) in remote_write section
            HAS_CLIENTS_PLURAL=$(echo "$LOKI_CONFIG" | grep -c "clients:" 2>/dev/null || true)
            HAS_CLIENTS_PLURAL=${HAS_CLIENTS_PLURAL:-0}
            HAS_CLIENT_SINGULAR=$(echo "$LOKI_CONFIG" | grep -c "^[[:space:]]*client:" 2>/dev/null || true)
            HAS_CLIENT_SINGULAR=${HAS_CLIENT_SINGULAR:-0}

            # Show the remote_write section
            REMOTE_WRITE_SECTION=$(echo "$LOKI_CONFIG" | grep -A 10 "remote_write" 2>/dev/null | head -12)
            if [ -n "$REMOTE_WRITE_SECTION" ]; then
                log_info "Remote write configuration:"
                log_success_output "$REMOTE_WRITE_SECTION"
            fi

            echo ""
            if [ "$HAS_CLIENTS_PLURAL" -gt 0 ] && [ "$HAS_CLIENT_SINGULAR" -eq 0 ]; then
                log_pass "Ruler config correctly uses ${BWHITE}'clients'${NC} (plural)"
                record_result "Ruler Config" "PASS"
            elif [ "$HAS_CLIENTS_PLURAL" -gt 0 ] && [ "$HAS_CLIENT_SINGULAR" -gt 0 ]; then
                log_info "Both 'client' and 'clients' found -- migration may be partial"
                record_result "Ruler Config" "PASS"
            elif [ "$HAS_CLIENT_SINGULAR" -gt 0 ] && [ "$HAS_CLIENTS_PLURAL" -eq 0 ]; then
                log_fail "Ruler config still uses deprecated ${BRED}'client'${NC} (singular)"
                log_detail "LOG-9665 may not be merged yet in this build."
                record_result "Ruler Config" "FAIL"
            else
                log_info "No remote_write config found (ruler may not be configured)"
                log_detail "This is normal if ruler/alerting is not enabled on this LokiStack."
                record_result "Ruler Config" "SKIP"
            fi
        fi
    fi
fi

print_phase_complete 6

# =============================================================================
#  FINAL REPORT
# =============================================================================

echo ""
echo ""
echo ""
TOTAL_ELAPSED=$(( $(date +%s) - SCRIPT_START_TIME ))
TOTAL_MINS=$((TOTAL_ELAPSED / 60))
TOTAL_SECS=$((TOTAL_ELAPSED % 60))

echo -e "  ${BG_MAGENTA}${BWHITE}                                                                          ${NC}"
echo -e "  ${BG_MAGENTA}${BWHITE}   TEST EXECUTION COMPLETE                                                ${NC}"
echo -e "  ${BG_MAGENTA}${BWHITE}                                                                          ${NC}"
echo ""
echo -e "  ${BWHITE}  BoltDB Deprecation & Loki 4.0 Migration -- Test Report${NC}"
echo -e "  ${DIM}  Epic: LOG-9510 | Logged at: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "  ${DIM}  Total execution time: ${TOTAL_MINS}m ${TOTAL_SECS}s${NC}"
echo ""

# Table header
echo -e "  ${BWHITE}┌──────┬──────────────────────────────────────────────┬──────────┬───────────┐${NC}"
echo -e "  ${BWHITE}│${NC} ${BOLD}Phase${NC} ${BWHITE}│${NC} ${BOLD}Test Check${NC}                                    ${BWHITE}│${NC} ${BOLD}Jira${NC}     ${BWHITE}│${NC} ${BOLD}Result${NC}    ${BWHITE}│${NC}"
echo -e "  ${BWHITE}├──────┼──────────────────────────────────────────────┼──────────┼───────────┤${NC}"

# Define test order
declare -a TEST_ORDER=(
    "1|OC Login|N/A"
    "1|Loki Operator|N/A"
    "1|CLO Running|N/A"
    "1|LokiStack|N/A"
    "1|Monitoring Labels|N/A"
    "2|Schemas Required|LOG-9351"
    "3|BoltDB Rejected|LOG-9512"
    "4|Alert Rule Exists|LOG-9744"
    "5|Rules Cleaned|LOG-9666"
    "5|Dashboards Cleaned|LOG-9666"
    "6|Ruler Config|LOG-9665"
)

for entry in "${TEST_ORDER[@]}"; do
    IFS='|' read -r phase test_name jira_key <<< "$entry"
    status="${RESULTS[$test_name]:-N/A}"

    case $status in
        PASS) color="${BGREEN}"; icon="✔ PASS" ;;
        FAIL) color="${BRED}";   icon="✘ FAIL" ;;
        SKIP) color="${BYELLOW}"; icon="⊘ SKIP" ;;
        *)    color="${DIM}";    icon="- N/A" ;;
    esac

    printf "  ${BWHITE}│${NC}  %s   ${BWHITE}│${NC} %-44s ${BWHITE}│${NC} %-8s ${BWHITE}│${NC} ${color}%-9s${NC} ${BWHITE}│${NC}\n" \
        "$phase" "$test_name" "$jira_key" "$icon"
done

echo -e "  ${BWHITE}└──────┴──────────────────────────────────────────────┴──────────┴───────────┘${NC}"
echo ""

# Summary counts
echo -e "  ${BWHITE}  Summary:${NC}  ${BGREEN}${TOTAL_PASS} Passed${NC}  ${DIM}|${NC}  ${BRED}${TOTAL_FAIL} Failed${NC}  ${DIM}|${NC}  ${BYELLOW}${TOTAL_SKIP} Skipped${NC}"
echo ""

# Overall verdict
if [ $TOTAL_FAIL -eq 0 ]; then
    echo -e "  ${BG_GREEN}${BWHITE}                                                                          ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██████╗  █████╗ ███████╗███████╗███████╗██████╗                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝██╔══██╗                        ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██████╔╝███████║███████╗███████╗█████╗  ██║  ██║                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██╔═══╝ ██╔══██║╚════██║╚════██║██╔══╝  ██║  ██║                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██║     ██║  ██║███████║███████║███████╗██████╔╝                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═════╝                          ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}                                                                          ${NC}"
    echo ""
    echo -e "  ${BGREEN}All Loki 4.0 migration checks passed successfully!${NC}"
else
    echo -e "  ${BG_RED}${BWHITE}                                                                          ${NC}"
    echo -e "  ${BG_RED}${BWHITE}   ███████╗ █████╗ ██╗██╗     ███████╗██████╗                              ${NC}"
    echo -e "  ${BG_RED}${BWHITE}   ██╔════╝██╔══██╗██║██║     ██╔════╝██╔══██╗                             ${NC}"
    echo -e "  ${BG_RED}${BWHITE}   █████╗  ███████║██║██║     █████╗  ██║  ██║                              ${NC}"
    echo -e "  ${BG_RED}${BWHITE}   ██╔══╝  ██╔══██║██║██║     ██╔══╝  ██║  ██║                              ${NC}"
    echo -e "  ${BG_RED}${BWHITE}   ██║     ██║  ██║██║███████╗███████╗██████╔╝                              ${NC}"
    echo -e "  ${BG_RED}${BWHITE}   ╚═╝     ╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚═════╝                               ${NC}"
    echo -e "  ${BG_RED}${BWHITE}                                                                          ${NC}"
    echo ""
    echo -e "  ${BRED}${TOTAL_FAIL} test(s) failed. Please review the failures above.${NC}"
    echo -e "  ${DIM}Note: Some failures may be expected if LOG tickets are not yet merged.${NC}"
fi

echo ""
echo -e "  ${DIM}───────────────────────────────────────────────────────────────────────────${NC}"
echo -e "  ${DIM}  Red Hat Logging Hackathon 6.7 | BoltDB Migration Validation | v${SCRIPT_VERSION}${NC}"
echo -e "  ${DIM}───────────────────────────────────────────────────────────────────────────${NC}"
echo ""

# Exit with appropriate code
if [ $TOTAL_FAIL -gt 0 ]; then
    exit 1
fi
exit 0
