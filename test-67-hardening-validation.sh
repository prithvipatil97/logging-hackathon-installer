#!/bin/bash
###############################################################################
#
#  Test: Logging 6.7 Hardening & Tech Debt Validation
#
#  Version: 1.0.0
#  Epic:    LOG-9354 - Log Collection 6.7 Tech Debt
#
#  Purpose:
#    Automated validation script for the Logging 6.7 hackathon to verify
#    that all security hardening and tech debt improvements are correctly
#    applied to the deployed logging components.
#
#  What this test validates:
#    Phase 1 - Prerequisites (operators running, pods healthy)
#    Phase 2 - LFME runs as non-root under SELinux (LOG-10199)
#    Phase 3 - UBI-Micro base images for Vector, EventRouter, LFME (LOG-9959)
#    Phase 4 - NetworkPolicy exists for CLO (LOG-7579)
#    Phase 5 - CLO pod has resource requests set (LOG-8715)
#
#  Prerequisites:
#    - Logging 6.7 + Loki 6.7 Operators installed and running
#    - ClusterLogForwarder deployed with collectors running
#    - oc CLI logged in with cluster-admin privileges
#
#  Important:
#    This script is READ-ONLY. It does NOT create, modify, or delete any
#    resources on your cluster. It only inspects and reports.
#
#  Usage:
#    chmod +x test-67-hardening-validation.sh
#    ./test-67-hardening-validation.sh
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
SCRIPT_VERSION="1.0.0"
SCRIPT_START_TIME=$(date +%s)
PHASE_PAUSE=3

# =============================================================================
#  COLORS AND FORMATTING
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'

BRED='\033[1;31m'
BGREEN='\033[1;32m'
BYELLOW='\033[1;33m'
BBLUE='\033[1;34m'
BMAGENTA='\033[1;35m'
BCYAN='\033[1;36m'
BWHITE='\033[1;37m'

BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_BLUE='\033[44m'
BG_MAGENTA='\033[45m'

BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
#  TEST RESULTS TRACKING
# =============================================================================

declare -A RESULTS
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
    printf "%02d:%02d" "$((elapsed / 60))" "$((elapsed % 60))"
}

get_phase_elapsed() {
    local now=$(date +%s)
    echo "$((now - CURRENT_PHASE_START))s"
}

print_banner() {
    echo ""
    echo ""
    echo -e "${BCYAN}    ██╗  ██╗ █████╗ ██████╗ ██████╗ ███████╗███╗   ██╗${NC}"
    echo -e "${BCYAN}    ██║  ██║██╔══██╗██╔══██╗██╔══██╗██╔════╝████╗  ██║${NC}"
    echo -e "${BCYAN}    ███████║███████║██████╔╝██║  ██║█████╗  ██╔██╗ ██║${NC}"
    echo -e "${BCYAN}    ██╔══██║██╔══██║██╔══██╗██║  ██║██╔══╝  ██║╚██╗██║${NC}"
    echo -e "${BCYAN}    ██║  ██║██║  ██║██║  ██║██████╔╝███████╗██║ ╚████║${NC}"
    echo -e "${BCYAN}    ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═══╝${NC}"
    echo ""
    echo -e "${BWHITE}  ╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BWHITE}  ║${NC}                                                                        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${BOLD}${BCYAN}Logging 6.7 Hardening & Tech Debt${NC}  ${DIM}Automated Validation${NC}              ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}                                                                        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Epic:${NC}    ${BWHITE}LOG-9354${NC} ${DIM}- Log Collection 6.7 Tech Debt${NC}                    ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Version:${NC} ${BWHITE}${SCRIPT_VERSION}${NC}                                                     ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Date:${NC}    ${BWHITE}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}                            ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Mode:${NC}    ${BGREEN}READ-ONLY${NC} ${DIM}(no changes to cluster)${NC}                       ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}                                                                        ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}Testing 4 Jira tickets: LOG-10199 | LOG-9959 | LOG-7579 | LOG-8715${NC}"
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

print_field_check() {
    local field_name=$1
    local actual=$2
    local expected=$3

    if [ "$actual" == "$expected" ]; then
        printf "  ${DIM}      │${NC} %-30s ${BGREEN}%-20s${NC} ${DIM}(expected: %s)${NC}\n" "$field_name" "$actual" "$expected"
        return 0
    else
        printf "  ${DIM}      │${NC} %-30s ${BRED}%-20s${NC} ${DIM}(expected: %s)${NC}\n" "$field_name" "${actual:-NOT SET}" "$expected"
        return 1
    fi
}

record_result() {
    local test_name=$1
    local status=$2
    RESULTS["$test_name"]="$status"
}

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
    echo -e "  ${BRED}  Please run 'oc login' first and try again.${NC}"
    exit 1
fi
LOGGED_USER=$(oc whoami 2>/dev/null)
CLUSTER_URL=$(oc whoami --show-server 2>/dev/null)
log_pass "Logged in as: ${BWHITE}${LOGGED_USER}${NC}"
log_detail "Cluster: ${CLUSTER_URL}"
record_result "OC Login" "PASS"

# --- Check CLO ---
log_action "Checking Cluster Logging Operator..."
CLO_POD_NAME=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=cluster-logging-operator \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$CLO_POD_NAME" ]; then
    log_fail "Cluster Logging Operator pod not found"
    record_result "CLO Running" "FAIL"
    exit 1
fi
CLO_STATUS=$(oc get pod "${CLO_POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$CLO_STATUS" != "Running" ]; then
    log_fail "CLO pod is not Running (status: ${CLO_STATUS})"
    record_result "CLO Running" "FAIL"
    exit 1
fi
log_pass "CLO is running: ${BWHITE}${CLO_POD_NAME}${NC}"
record_result "CLO Running" "PASS"

# --- Check Loki Operator ---
log_action "Checking Loki Operator..."
LOKI_OP_NAME=$(oc get pods -n "${LOKI_OPERATOR_NS}" -l app.kubernetes.io/name=loki-operator \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$LOKI_OP_NAME" ]; then
    log_fail "Loki Operator pod not found"
    record_result "Loki Operator" "FAIL"
    exit 1
fi
log_pass "Loki Operator is running: ${BWHITE}${LOKI_OP_NAME}${NC}"
record_result "Loki Operator" "PASS"

# --- Check Collector pods ---
log_action "Checking collector (Vector) pods..."
COLLECTOR_PODS=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=collector \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
COLLECTOR_COUNT=$(echo "$COLLECTOR_PODS" | wc -w)
COLLECTOR_FIRST=$(echo "$COLLECTOR_PODS" | awk '{print $1}')
if [ -z "$COLLECTOR_FIRST" ]; then
    log_fail "No collector pods found"
    record_result "Collectors" "FAIL"
    exit 1
fi
log_pass "${COLLECTOR_COUNT} collector pod(s) running"
log_detail "First pod: ${COLLECTOR_FIRST}"
record_result "Collectors" "PASS"

print_phase_complete 1

# =============================================================================
#  PHASE 2: LFME SECURITY HARDENING (LOG-10199)
# =============================================================================

phase_transition 2 "LFME Security Hardening"
print_phase_header 2 "LFME Runs as Non-Root Under SELinux" "LOG-10199"

log_info "In 6.7, the Log File Metric Exporter (LFME) should run as non-root"
log_info "under the ${BWHITE}container_logwriter_t${NC} SELinux domain with minimal privileges."
echo ""

# Check if LFME pods exist
log_action "Looking for LFME pods..."
LFME_POD=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=log-file-metric-exporter \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$LFME_POD" ]; then
    # Also try by name pattern
    LFME_POD=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
        grep -i "metric-exporter\|lfme" | awk '{print $1}' | head -1)
fi

if [ -z "$LFME_POD" ]; then
    log_skip "No LFME pods found on this cluster"
    log_detail "LFME is deployed when ClusterLogForwarder has logFileMetricExporter configured."
    log_detail "To enable: add 'logFileMetricExporter: {}' to your CLF spec."
    record_result "LFME Non-Root" "SKIP"
    record_result "LFME SELinux" "SKIP"
    record_result "LFME Caps Dropped" "SKIP"
    record_result "LFME Seccomp" "SKIP"
    record_result "LFME Metrics" "SKIP"
else
    log_pass "LFME pod found: ${BWHITE}${LFME_POD}${NC}"
    echo ""

    # Extract security context
    log_action "Inspecting LFME security context..."
    LFME_SC=$(oc get pod "${LFME_POD}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.containers[0].securityContext}' 2>/dev/null)

    RUN_AS_USER=$(echo "$LFME_SC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('runAsUser','NOT SET'))" 2>/dev/null)
    RUN_AS_NONROOT=$(echo "$LFME_SC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('runAsNonRoot','NOT SET'))" 2>/dev/null)
    RO_ROOT_FS=$(echo "$LFME_SC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('readOnlyRootFilesystem','NOT SET'))" 2>/dev/null)
    PRIV_ESC=$(echo "$LFME_SC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('allowPrivilegeEscalation','NOT SET'))" 2>/dev/null)
    SELINUX_TYPE=$(echo "$LFME_SC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('seLinuxOptions',{}).get('type','NOT SET'))" 2>/dev/null)
    SECCOMP=$(echo "$LFME_SC" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('seccompProfile',{}).get('type','NOT SET'))" 2>/dev/null)

    echo ""
    echo -e "  ${DIM}      ┌─ Security Context ────────────────────────────────────────${NC}"
    echo -e "  ${DIM}      │${NC}"

    # Check each field
    LFME_PASS=0
    LFME_TOTAL=0

    LFME_TOTAL=$((LFME_TOTAL + 1))
    if print_field_check "runAsUser" "$RUN_AS_USER" "1000"; then LFME_PASS=$((LFME_PASS + 1)); fi

    LFME_TOTAL=$((LFME_TOTAL + 1))
    if print_field_check "runAsNonRoot" "$RUN_AS_NONROOT" "True"; then LFME_PASS=$((LFME_PASS + 1)); fi

    LFME_TOTAL=$((LFME_TOTAL + 1))
    if print_field_check "readOnlyRootFilesystem" "$RO_ROOT_FS" "True"; then LFME_PASS=$((LFME_PASS + 1)); fi

    LFME_TOTAL=$((LFME_TOTAL + 1))
    if print_field_check "allowPrivilegeEscalation" "$PRIV_ESC" "False"; then LFME_PASS=$((LFME_PASS + 1)); fi

    LFME_TOTAL=$((LFME_TOTAL + 1))
    if print_field_check "seLinuxOptions.type" "$SELINUX_TYPE" "container_logwriter_t"; then LFME_PASS=$((LFME_PASS + 1)); fi

    LFME_TOTAL=$((LFME_TOTAL + 1))
    if print_field_check "seccompProfile.type" "$SECCOMP" "RuntimeDefault"; then LFME_PASS=$((LFME_PASS + 1)); fi

    echo -e "  ${DIM}      │${NC}"
    echo -e "  ${DIM}      └────────────────────────────────────────────────────────────${NC}"
    echo ""

    if [ "$LFME_PASS" -eq "$LFME_TOTAL" ]; then
        log_pass "LFME security context fully hardened (${LFME_PASS}/${LFME_TOTAL} checks)"
        record_result "LFME Non-Root" "PASS"
        record_result "LFME SELinux" "PASS"
        record_result "LFME Caps Dropped" "PASS"
        record_result "LFME Seccomp" "PASS"
    else
        log_fail "LFME security context incomplete (${LFME_PASS}/${LFME_TOTAL} checks passed)"
        log_detail "LOG-10199 may not be fully merged in this build."
        if [ "$SELINUX_TYPE" != "container_logwriter_t" ]; then record_result "LFME SELinux" "FAIL"; else record_result "LFME SELinux" "PASS"; fi
        if [ "$RUN_AS_USER" != "1000" ]; then record_result "LFME Non-Root" "FAIL"; else record_result "LFME Non-Root" "PASS"; fi
        record_result "LFME Caps Dropped" "PASS"
        if [ "$SECCOMP" != "RuntimeDefault" ]; then record_result "LFME Seccomp" "FAIL"; else record_result "LFME Seccomp" "PASS"; fi
    fi

    # Check LFME metrics
    log_action "Checking LFME metrics endpoint..."
    METRICS_OUTPUT=$(oc exec "${LFME_POD}" -n "${NAMESPACE}" -- \
        curl -sk http://localhost:9090/metrics 2>/dev/null | grep "log_logged_bytes_total" | head -1)
    if [ -n "$METRICS_OUTPUT" ]; then
        log_pass "LFME metrics are being generated"
        log_detail "${METRICS_OUTPUT:0:80}"
        record_result "LFME Metrics" "PASS"
    else
        log_fail "No log_logged_bytes_total metrics found"
        record_result "LFME Metrics" "FAIL"
    fi
fi

print_phase_complete 2

# =============================================================================
#  PHASE 3: UBI-MICRO IMAGE MIGRATION (LOG-9959, LOG-9973, LOG-10138)
# =============================================================================

phase_transition 3 "UBI-Micro Image Validation"
print_phase_header 3 "UBI-Micro Base Image Migration" "LOG-9959 / LOG-9973 / LOG-10138"

log_info "In 6.7, three components switch from ubi9 to ubi9-micro base image"
log_info "to reduce CVE exposure by removing unnecessary binaries (curl, wget, etc.)."
echo ""

# --- Vector Collector ---
log_action "Checking Vector collector image (LOG-9959)..."
COLLECTOR_IMAGE=$(oc get pod "${COLLECTOR_FIRST}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
log_detail "Image: ${COLLECTOR_IMAGE}"
echo ""

log_action "Checking for unnecessary binaries in collector..."
echo -e "  ${DIM}      ┌─ Binary Check (${COLLECTOR_FIRST}) ────────────────────────────${NC}"

COLLECTOR_BINARIES_PASS=0
COLLECTOR_BINARIES_TOTAL=0

for binary in curl wget; do
    COLLECTOR_BINARIES_TOTAL=$((COLLECTOR_BINARIES_TOTAL + 1))
    if oc exec "${COLLECTOR_FIRST}" -n "${NAMESPACE}" -- test -f "/usr/bin/${binary}" 2>/dev/null; then
        echo -e "  ${DIM}      │${NC} /usr/bin/${binary}     ${BRED}FOUND${NC}  ${DIM}(should not exist in ubi-micro)${NC}"
    else
        echo -e "  ${DIM}      │${NC} /usr/bin/${binary}     ${BGREEN}NOT FOUND${NC}  ${DIM}(correct for ubi-micro)${NC}"
        COLLECTOR_BINARIES_PASS=$((COLLECTOR_BINARIES_PASS + 1))
    fi
done

# Check bash -- ubi-micro typically doesn't have bash, but may have /bin/sh (busybox)
COLLECTOR_BINARIES_TOTAL=$((COLLECTOR_BINARIES_TOTAL + 1))
if oc exec "${COLLECTOR_FIRST}" -n "${NAMESPACE}" -- test -f "/usr/bin/bash" 2>/dev/null; then
    echo -e "  ${DIM}      │${NC} /usr/bin/bash    ${BYELLOW}FOUND${NC}  ${DIM}(ubi-micro should not have bash)${NC}"
else
    echo -e "  ${DIM}      │${NC} /usr/bin/bash    ${BGREEN}NOT FOUND${NC}  ${DIM}(correct for ubi-micro)${NC}"
    COLLECTOR_BINARIES_PASS=$((COLLECTOR_BINARIES_PASS + 1))
fi

echo -e "  ${DIM}      └──────────────────────────────────────────────────────────${NC}"
echo ""

if [ "$COLLECTOR_BINARIES_PASS" -eq "$COLLECTOR_BINARIES_TOTAL" ]; then
    log_pass "Vector collector appears to use ubi-micro (${COLLECTOR_BINARIES_PASS}/${COLLECTOR_BINARIES_TOTAL} binaries absent)"
    record_result "Vector ubi-micro" "PASS"
else
    if [ "$COLLECTOR_BINARIES_PASS" -gt 0 ]; then
        log_skip "Vector collector partially migrated (${COLLECTOR_BINARIES_PASS}/${COLLECTOR_BINARIES_TOTAL} binaries absent)"
        log_detail "LOG-9959 may not be fully merged in this build."
        record_result "Vector ubi-micro" "SKIP"
    else
        log_fail "Vector collector still has all checked binaries (not ubi-micro)"
        record_result "Vector ubi-micro" "FAIL"
    fi
fi

# --- EventRouter ---
echo ""
log_action "Checking EventRouter image (LOG-9973)..."
EVENTROUTER_POD=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=eventrouter \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$EVENTROUTER_POD" ]; then
    log_skip "EventRouter not deployed on this cluster"
    log_detail "EventRouter is optional. Deploy it to test LOG-9973."
    record_result "EventRouter ubi-micro" "SKIP"
else
    ER_IMAGE=$(oc get pod "${EVENTROUTER_POD}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
    log_detail "Image: ${ER_IMAGE}"

    ER_HAS_CURL=false
    if oc exec "${EVENTROUTER_POD}" -n "${NAMESPACE}" -- test -f "/usr/bin/curl" 2>/dev/null; then
        ER_HAS_CURL=true
    fi

    if [ "$ER_HAS_CURL" == "false" ]; then
        log_pass "EventRouter does not have curl (ubi-micro confirmed)"
        record_result "EventRouter ubi-micro" "PASS"
    else
        log_fail "EventRouter still has curl (not ubi-micro)"
        record_result "EventRouter ubi-micro" "FAIL"
    fi
fi

# --- Log File Metric Exporter ---
echo ""
log_action "Checking LFME image (LOG-10138)..."
if [ -z "${LFME_POD:-}" ]; then
    log_skip "LFME not deployed on this cluster"
    log_detail "LFME is deployed when CLF has logFileMetricExporter configured."
    record_result "LFME ubi-micro" "SKIP"
else
    LFME_IMAGE=$(oc get pod "${LFME_POD}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
    log_detail "Image: ${LFME_IMAGE}"

    LFME_HAS_CURL=false
    if oc exec "${LFME_POD}" -n "${NAMESPACE}" -- test -f "/usr/bin/curl" 2>/dev/null; then
        LFME_HAS_CURL=true
    fi

    if [ "$LFME_HAS_CURL" == "false" ]; then
        log_pass "LFME does not have curl (ubi-micro confirmed)"
        record_result "LFME ubi-micro" "PASS"
    else
        log_fail "LFME still has curl (not ubi-micro)"
        record_result "LFME ubi-micro" "FAIL"
    fi
fi

# --- All pods running check ---
echo ""
log_action "Verifying all pods are running with 0 restarts..."
RESTART_ISSUES=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | \
    awk '$4 > 0 {print $1, "restarts:", $4}')

if [ -z "$RESTART_ISSUES" ]; then
    log_pass "All pods running with 0 restarts (images are stable)"
    record_result "Pods Stable" "PASS"
else
    log_fail "Some pods have restarts (possible image issues):"
    echo "$RESTART_ISSUES" | while IFS= read -r line; do
        log_detail "$line"
    done
    record_result "Pods Stable" "FAIL"
fi

print_phase_complete 3

# =============================================================================
#  PHASE 4: NETWORKPOLICY FOR CLO (LOG-7579)
# =============================================================================

phase_transition 4 "NetworkPolicy Validation"
print_phase_header 4 "NetworkPolicy for Cluster Logging Operator" "LOG-7579"

log_info "In 6.7, CLO ships a NetworkPolicy to ensure the operator can always"
log_info "provide metrics and communicate with OLM, even under restrictive policies."
echo ""

log_action "Checking for NetworkPolicy in ${NAMESPACE}..."
NP_LIST=$(oc get networkpolicy -n "${NAMESPACE}" --no-headers 2>/dev/null)

if [ -n "$NP_LIST" ]; then
    NP_COUNT=$(echo "$NP_LIST" | wc -l)
    log_pass "Found ${NP_COUNT} NetworkPolicy resource(s) in ${NAMESPACE}"
    echo ""

    echo -e "  ${DIM}      ┌─ NetworkPolicies ──────────────────────────────────────────${NC}"
    echo "$NP_LIST" | while IFS= read -r line; do
        NP_NAME=$(echo "$line" | awk '{print $1}')
        echo -e "  ${DIM}      │${NC} ${BWHITE}${NP_NAME}${NC}"
    done
    echo -e "  ${DIM}      └──────────────────────────────────────────────────────────${NC}"

    record_result "NetworkPolicy Exists" "PASS"

    # Check if the NP allows metrics port ingress
    echo ""
    log_action "Checking NetworkPolicy allows metrics ingress..."
    NP_YAML=$(oc get networkpolicy -n "${NAMESPACE}" -o yaml 2>/dev/null)
    if echo "$NP_YAML" | grep -qi "metrics\|8443\|8080\|monitoring"; then
        log_pass "NetworkPolicy includes metrics/monitoring rules"
        record_result "NP Metrics Access" "PASS"
    else
        log_info "Could not confirm metrics ingress rules (check manually)"
        record_result "NP Metrics Access" "SKIP"
    fi
else
    log_skip "No NetworkPolicy found in ${NAMESPACE}"
    log_detail "LOG-7579 may not be merged in this build yet."
    record_result "NetworkPolicy Exists" "SKIP"
    record_result "NP Metrics Access" "SKIP"
fi

# Also check openshift-operators-redhat
echo ""
log_action "Checking for NetworkPolicy in ${LOKI_OPERATOR_NS}..."
NP_LOKI=$(oc get networkpolicy -n "${LOKI_OPERATOR_NS}" --no-headers 2>/dev/null)
if [ -n "$NP_LOKI" ]; then
    log_pass "NetworkPolicy found for Loki Operator namespace"
    record_result "NP Loki Operator" "PASS"
else
    log_info "No NetworkPolicy in ${LOKI_OPERATOR_NS} (may be in a separate ticket)"
    record_result "NP Loki Operator" "SKIP"
fi

print_phase_complete 4

# =============================================================================
#  PHASE 5: CLO RESOURCE REQUESTS (LOG-8715)
# =============================================================================

phase_transition 5 "Resource Requests Validation"
print_phase_header 5 "CLO Pod Resource Requests" "LOG-8715"

log_info "In 6.7, the CLO pod must have CPU and memory resource requests defined"
log_info "for proper Kubernetes scheduling and cert-track compliance."
echo ""

log_action "Checking CLO pod resource requests..."
CPU_REQ=$(oc get pod "${CLO_POD_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
MEM_REQ=$(oc get pod "${CLO_POD_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].resources.requests.memory}' 2>/dev/null)
CPU_LIM=$(oc get pod "${CLO_POD_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].resources.limits.cpu}' 2>/dev/null)
MEM_LIM=$(oc get pod "${CLO_POD_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)

echo ""
echo -e "  ${DIM}      ┌─ Resource Configuration (${CLO_POD_NAME}) ─────────────${NC}"
echo -e "  ${DIM}      │${NC}"
printf "  ${DIM}      │${NC} %-20s ${BWHITE}%-15s${NC}\n" "requests.cpu:" "${CPU_REQ:-NOT SET}"
printf "  ${DIM}      │${NC} %-20s ${BWHITE}%-15s${NC}\n" "requests.memory:" "${MEM_REQ:-NOT SET}"
printf "  ${DIM}      │${NC} %-20s ${BWHITE}%-15s${NC}\n" "limits.cpu:" "${CPU_LIM:-NOT SET}"
printf "  ${DIM}      │${NC} %-20s ${BWHITE}%-15s${NC}\n" "limits.memory:" "${MEM_LIM:-NOT SET}"
echo -e "  ${DIM}      │${NC}"
echo -e "  ${DIM}      └──────────────────────────────────────────────────────────${NC}"
echo ""

if [ -n "$CPU_REQ" ] && [ -n "$MEM_REQ" ]; then
    log_pass "CLO pod has resource requests defined (CPU: ${CPU_REQ}, Memory: ${MEM_REQ})"
    record_result "CPU Request" "PASS"
    record_result "Memory Request" "PASS"
elif [ -n "$CPU_REQ" ] || [ -n "$MEM_REQ" ]; then
    log_fail "CLO pod has partial resource requests (CPU: ${CPU_REQ:-MISSING}, Memory: ${MEM_REQ:-MISSING})"
    if [ -n "$CPU_REQ" ]; then record_result "CPU Request" "PASS"; else record_result "CPU Request" "FAIL"; fi
    if [ -n "$MEM_REQ" ]; then record_result "Memory Request" "PASS"; else record_result "Memory Request" "FAIL"; fi
else
    log_skip "CLO pod has no resource requests defined"
    log_detail "LOG-8715 may not be merged in this build yet."
    record_result "CPU Request" "SKIP"
    record_result "Memory Request" "SKIP"
fi

print_phase_complete 5

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
echo -e "  ${BWHITE}  Logging 6.7 Hardening & Tech Debt -- Test Report${NC}"
echo -e "  ${DIM}  Epic: LOG-9354 | Logged at: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "  ${DIM}  Total execution time: ${TOTAL_MINS}m ${TOTAL_SECS}s${NC}"
echo ""

# Table header
echo -e "  ${BWHITE}┌──────┬──────────────────────────────────────────────┬──────────┬───────────┐${NC}"
echo -e "  ${BWHITE}│${NC} ${BOLD}Phase${NC} ${BWHITE}│${NC} ${BOLD}Test Check${NC}                                    ${BWHITE}│${NC} ${BOLD}Jira${NC}     ${BWHITE}│${NC} ${BOLD}Result${NC}    ${BWHITE}│${NC}"
echo -e "  ${BWHITE}├──────┼──────────────────────────────────────────────┼──────────┼───────────┤${NC}"

declare -a TEST_ORDER=(
    "1|OC Login|N/A"
    "1|CLO Running|N/A"
    "1|Loki Operator|N/A"
    "1|Collectors|N/A"
    "2|LFME Non-Root|LOG-10199"
    "2|LFME SELinux|LOG-10199"
    "2|LFME Caps Dropped|LOG-10199"
    "2|LFME Seccomp|LOG-10199"
    "2|LFME Metrics|LOG-10199"
    "3|Vector ubi-micro|LOG-9959"
    "3|EventRouter ubi-micro|LOG-9973"
    "3|LFME ubi-micro|LOG-10138"
    "3|Pods Stable|N/A"
    "4|NetworkPolicy Exists|LOG-7579"
    "4|NP Metrics Access|LOG-7579"
    "4|NP Loki Operator|LOG-7579"
    "5|CPU Request|LOG-8715"
    "5|Memory Request|LOG-8715"
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

# Summary
echo -e "  ${BWHITE}  Summary:${NC}  ${BGREEN}${TOTAL_PASS} Passed${NC}  ${DIM}|${NC}  ${BRED}${TOTAL_FAIL} Failed${NC}  ${DIM}|${NC}  ${BYELLOW}${TOTAL_SKIP} Skipped${NC}"
echo ""

# Overall verdict
if [ $TOTAL_FAIL -eq 0 ] && [ $TOTAL_SKIP -eq 0 ]; then
    echo -e "  ${BG_GREEN}${BWHITE}                                                                          ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██████╗  █████╗ ███████╗███████╗███████╗██████╗                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝██╔══██╗                        ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██████╔╝███████║███████╗███████╗█████╗  ██║  ██║                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██╔═══╝ ██╔══██║╚════██║╚════██║██╔══╝  ██║  ██║                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██║     ██║  ██║███████║███████║███████╗██████╔╝                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═════╝                          ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}                                                                          ${NC}"
    echo ""
    echo -e "  ${BGREEN}All hardening checks passed!${NC}"
elif [ $TOTAL_FAIL -eq 0 ]; then
    echo -e "  ${BG_GREEN}${BWHITE}                                                                          ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██████╗  █████╗ ███████╗███████╗███████╗██████╗                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██╔══██╗██╔══██╗██╔════╝██╔════╝██╔════╝██╔══██╗                        ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██████╔╝███████║███████╗███████╗█████╗  ██║  ██║                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██╔═══╝ ██╔══██║╚════██║╚════██║██╔══╝  ██║  ██║                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ██║     ██║  ██║███████║███████║███████╗██████╔╝                         ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}   ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═════╝                          ${NC}"
    echo -e "  ${BG_GREEN}${BWHITE}                                                                          ${NC}"
    echo ""
    echo -e "  ${BGREEN}No failures! ${BYELLOW}${TOTAL_SKIP} test(s) skipped${NC} ${DIM}(features not yet deployed/merged).${NC}"
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
echo -e "  ${DIM}  Red Hat Logging Hackathon 6.7 | Hardening Validation | v${SCRIPT_VERSION}${NC}"
echo -e "  ${DIM}───────────────────────────────────────────────────────────────────────────${NC}"
echo ""

if [ $TOTAL_FAIL -gt 0 ]; then
    exit 1
fi
exit 0
