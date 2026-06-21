#!/bin/bash
###############################################################################
# Test: ClusterLogForwarderNotReady Alert Validation
#
# Purpose:
#   Automated test to verify that the ClusterLogForwarderNotReady alert fires
#   correctly when a ClusterLogForwarder has a validation error.
#
# Prerequisites:
#   - Cluster Logging Operator (CLO) installed and running
#   - oc CLI logged in with cluster-admin privileges
#   - Access to OpenShift web console (for visual alert verification)
#
# Usage:
#   chmod +x test-clf-not-ready-alert.sh
#   ./test-clf-not-ready-alert.sh
#
# What this test does:
#   1. Checks prerequisites (CLO running, namespace labeled for monitoring)
#   2. Creates a valid ClusterLogForwarder
#   3. Injects a validation failure into the CLF
#   4. Verifies the log_forwarder_ready metric flips to False
#   5. Waits for the ClusterLogForwarderNotReady alert to fire
#   6. Gives you 4 minutes to verify the alert on the web console
#   7. Cleans up the test resources
#
# No LokiStack deployment is required for this test.
###############################################################################

set -euo pipefail

# --- Configuration ---
NAMESPACE="openshift-logging"
CLF_NAME="collector"
MONITORING_NS="openshift-monitoring"
ALERT_NAME="ClusterLogForwarderNotReady"
METRIC_NAME="log_forwarder_ready"
WAIT_FOR_ALERT_TIMEOUT=120    # seconds to wait for alert to fire
WEBCONSOLE_PAUSE=240          # 4 minutes for manual verification
CLEANUP_WAIT=30               # seconds to wait after cleanup

# --- Colors and Formatting ---
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
NC='\033[0m' # No Color
BOLD='\033[1m'
BLINK='\033[5m'

# --- Test Results Tracking ---
declare -A RESULTS
TOTAL_PASS=0
TOTAL_FAIL=0

# --- Helper Functions ---

print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}${WHITE}ClusterLogForwarderNotReady Alert - Automated Test${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}Jira: LOG-7717${NC}                                                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_phase() {
    local phase_num=$1
    local phase_name=$2
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Phase ${phase_num}: ${phase_name}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

log_info() {
    echo -e "  ${CYAN}[INFO]${NC}  $1"
}

log_pass() {
    echo -e "  ${GREEN}[PASS]${NC}  $1"
    TOTAL_PASS=$((TOTAL_PASS + 1))
}

log_fail() {
    echo -e "  ${RED}[FAIL]${NC}  $1"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

log_wait() {
    echo -e "  ${YELLOW}[WAIT]${NC}  $1"
}

record_result() {
    local test_name=$1
    local status=$2
    RESULTS["$test_name"]="$status"
}

query_prometheus() {
    local query=$1
    oc exec -n "${MONITORING_NS}" -c prometheus prometheus-k8s-0 -- \
        curl -s "http://localhost:9090/api/v1/query?query=${query}" 2>/dev/null
}

check_alert_state() {
    local result
    result=$(query_prometheus "ALERTS%7Balertname%3D%22${ALERT_NAME}%22%7D")
    if echo "$result" | grep -q '"firing"'; then
        return 0
    fi
    return 1
}

countdown_timer() {
    local total_seconds=$1
    local remaining=$total_seconds

    while [ $remaining -gt 0 ]; do
        local mins=$((remaining / 60))
        local secs=$((remaining % 60))
        printf "\r  ${YELLOW}⏱  Time remaining: %dm %02ds ${NC}  " "$mins" "$secs"
        sleep 1
        remaining=$((remaining - 1))
    done
    printf "\r  ${GREEN}⏱  Time's up! Proceeding...                    ${NC}\n"
}

cleanup() {
    log_info "Cleaning up test resources..."
    oc delete clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE} --ignore-not-found=true 2>/dev/null || true
}

trap cleanup EXIT

# =============================================================================
# MAIN TEST EXECUTION
# =============================================================================

print_header

# --- Phase 1: Prerequisites Check ---
print_phase 1 "Prerequisites Check"

# Check oc is logged in
log_info "Checking oc CLI access..."
if ! oc whoami &>/dev/null; then
    log_fail "Not logged in to OpenShift cluster. Run 'oc login' first."
    exit 1
fi
log_pass "Logged in as: $(oc whoami)"

# Check CLO is installed and running
log_info "Checking Cluster Logging Operator..."
CLO_POD=$(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/name=cluster-logging-operator -o name 2>/dev/null | head -1)
if [ -z "$CLO_POD" ]; then
    log_fail "Cluster Logging Operator pod not found in ${NAMESPACE}"
    log_info "Please install CLO first using the automation script."
    exit 1
fi
CLO_STATUS=$(oc get ${CLO_POD} -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$CLO_STATUS" != "Running" ]; then
    log_fail "CLO pod is not Running (status: ${CLO_STATUS})"
    exit 1
fi
log_pass "CLO is running: ${CLO_POD}"
record_result "CLO Running" "PASS"

# Ensure namespace has monitoring label
log_info "Checking namespace monitoring label..."
HAS_LABEL=$(oc get namespace ${NAMESPACE} -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null)
if [ "$HAS_LABEL" != "true" ]; then
    log_info "Adding openshift.io/cluster-monitoring=true label to ${NAMESPACE}..."
    oc label namespace ${NAMESPACE} openshift.io/cluster-monitoring=true --overwrite 2>/dev/null
    log_pass "Label added. Prometheus will start scraping in ~30s."
    sleep 10
else
    log_pass "Namespace already has monitoring label."
fi
record_result "Monitoring Label" "PASS"

# Verify ServiceMonitor exists
log_info "Checking ServiceMonitor..."
if oc get servicemonitor cluster-logging-operator-metrics-monitor -n ${NAMESPACE} &>/dev/null; then
    log_pass "ServiceMonitor exists."
    record_result "ServiceMonitor" "PASS"
else
    log_fail "ServiceMonitor 'cluster-logging-operator-metrics-monitor' not found."
    record_result "ServiceMonitor" "FAIL"
    exit 1
fi

# --- Phase 2: Create Valid CLF (Baseline) ---
print_phase 2 "Create Valid ClusterLogForwarder (Baseline)"

log_info "Applying valid CLF configuration..."
cat <<'EOF' | oc apply -f - 2>/dev/null
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
spec:
  managementState: Managed
  outputs:
  - name: default-lokistack
    type: lokiStack
    lokiStack:
      target:
        name: logging-loki
        namespace: openshift-logging
      authentication:
        token:
          from: serviceAccount
    tls:
      ca:
        configMapName: openshift-service-ca.crt
        key: service-ca.crt
  pipelines:
  - name: default-logstore
    inputRefs:
    - application
    - infrastructure
    outputRefs:
    - default-lokistack
  serviceAccount:
    name: collector
EOF

# Wait for CLF to become Ready
log_wait "Waiting for CLF to become Ready..."
for i in $(seq 1 60); do
    READY=$(oc get clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$READY" == "True" ]; then
        break
    fi
    sleep 2
done

if [ "$READY" == "True" ]; then
    log_pass "CLF is Ready (baseline confirmed)."
    record_result "CLF Baseline Ready" "PASS"
else
    log_info "CLF did not reach Ready state (this is OK if LokiStack is not deployed)."
    log_info "Proceeding - the test only needs the CLF to exist for the metric to be emitted."
    record_result "CLF Baseline Ready" "SKIP"
fi

# Wait for metric to appear in Prometheus
log_wait "Waiting for metric '${METRIC_NAME}' to appear in Prometheus (up to 90s)..."
METRIC_FOUND=false
for i in $(seq 1 30); do
    RESULT=$(query_prometheus "${METRIC_NAME}")
    if echo "$RESULT" | grep -q '"result":\[{'; then
        METRIC_FOUND=true
        break
    fi
    sleep 3
done

if [ "$METRIC_FOUND" == "true" ]; then
    log_pass "Metric '${METRIC_NAME}' is being scraped by Prometheus."
    record_result "Metric Scraped" "PASS"
else
    log_fail "Metric '${METRIC_NAME}' not found in Prometheus after 90s."
    log_info "Ensure the ServiceMonitor is being picked up. Check: oc get targets in Prometheus UI."
    record_result "Metric Scraped" "FAIL"
    exit 1
fi

# --- Phase 3: Inject Validation Failure ---
print_phase 3 "Inject Validation Failure"

log_info "Patching CLF with invalid pipeline (referencing non-existent output)..."
oc patch clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE} --type='merge' -p '
{
  "spec": {
    "pipelines": [
      {
        "name": "broken-pipeline",
        "inputRefs": ["application"],
        "outputRefs": ["this-output-does-not-exist"]
      }
    ]
  }
}' 2>/dev/null

log_pass "Invalid patch applied."

# Wait for CLF to become Not Ready
log_wait "Waiting for CLF to report Ready=False..."
CLF_NOT_READY=false
for i in $(seq 1 30); do
    READY=$(oc get clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$READY" == "False" ]; then
        CLF_NOT_READY=true
        break
    fi
    sleep 2
done

if [ "$CLF_NOT_READY" == "true" ]; then
    REASON=$(oc get clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
    log_pass "CLF is NOT ready. Reason: ${REASON}"
    record_result "CLF Not Ready" "PASS"
else
    log_fail "CLF did not transition to Ready=False within 60s."
    record_result "CLF Not Ready" "FAIL"
fi

# --- Phase 4: Verify Alert Fires ---
print_phase 4 "Verify Alert Fires"

# Verify metric shows False
log_wait "Verifying metric shows status=False..."
METRIC_FALSE=false
for i in $(seq 1 20); do
    RESULT=$(query_prometheus "${METRIC_NAME}%7Bstatus%3D%22False%22%7D")
    if echo "$RESULT" | grep -q '"value":\[.*,"1"\]'; then
        METRIC_FALSE=true
        break
    fi
    sleep 3
done

if [ "$METRIC_FALSE" == "true" ]; then
    log_pass "Metric confirmed: log_forwarder_ready{status=\"False\"} = 1"
    record_result "Metric False=1" "PASS"
else
    log_fail "Metric did not show status=False within 60s."
    record_result "Metric False=1" "FAIL"
fi

# Wait for alert to fire (needs 1m for: duration + scrape interval)
log_wait "Waiting for ${ALERT_NAME} alert to fire (up to ${WAIT_FOR_ALERT_TIMEOUT}s)..."
ALERT_FIRED=false
for i in $(seq 1 $((WAIT_FOR_ALERT_TIMEOUT / 5))); do
    if check_alert_state; then
        ALERT_FIRED=true
        break
    fi
    sleep 5
done

if [ "$ALERT_FIRED" == "true" ]; then
    log_pass "${ALERT_NAME} alert is FIRING!"
    record_result "Alert Firing" "PASS"
else
    log_fail "${ALERT_NAME} alert did not fire within ${WAIT_FOR_ALERT_TIMEOUT}s."
    record_result "Alert Firing" "FAIL"
fi

# --- Phase 4b: Interactive Validation Pause ---
echo ""
echo ""
echo -e "${BG_RED}${WHITE}${BOLD}                                                                        ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ╔════════════════════════════════════════════════════════════════╗    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║                                                              ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║        ALERT IS NOW FIRING!                                  ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║                                                              ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║   Please validate on the OpenShift Web Console:              ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║                                                              ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║     Observe  =>  Alerting  =>  ClusterLogForwarderNotReady   ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ║                                                              ║    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}   ╚════════════════════════════════════════════════════════════════╝    ${NC}"
echo -e "${BG_RED}${WHITE}${BOLD}                                                                        ${NC}"
echo ""
echo -e "  ${YELLOW}${BOLD}You have 4 MINUTES to verify the alert on the web console.${NC}"
echo -e "  ${YELLOW}${BOLD}After the countdown, the test will proceed to cleanup.${NC}"
echo ""

countdown_timer ${WEBCONSOLE_PAUSE}

echo ""
echo -e "  ${GREEN}${BOLD}Countdown complete. Proceeding to cleanup...${NC}"
echo ""

# --- Phase 5: Cleanup ---
print_phase 5 "Cleanup"

log_info "Removing test CLF to resolve the alert..."
oc delete clusterlogforwarder ${CLF_NAME} -n ${NAMESPACE} --ignore-not-found=true 2>/dev/null
log_pass "Test CLF deleted. Alert will auto-resolve shortly."
record_result "Cleanup" "PASS"

log_wait "Waiting ${CLEANUP_WAIT}s for alert to resolve..."
sleep ${CLEANUP_WAIT}

# Check if alert resolved
ALERT_RESOLVED=true
if check_alert_state; then
    ALERT_RESOLVED=false
fi

if [ "$ALERT_RESOLVED" == "true" ]; then
    log_pass "Alert has resolved."
    record_result "Alert Resolved" "PASS"
else
    log_info "Alert is still active (may take a few more minutes to fully resolve)."
    record_result "Alert Resolved" "INFO"
fi

# --- Phase 6: Final Report ---
print_phase 6 "Test Report"

echo ""
echo -e "  ${BOLD}${WHITE}Test Case: ClusterLogForwarderNotReady Alert Validation${NC}"
echo -e "  ${BOLD}${WHITE}Jira: LOG-7717${NC}"
echo ""
echo -e "  ┌────────────────────────────┬──────────┐"
echo -e "  │ ${BOLD}Check${NC}                      │ ${BOLD}Result${NC}   │"
echo -e "  ├────────────────────────────┼──────────┤"

for test_name in "CLO Running" "Monitoring Label" "ServiceMonitor" "CLF Baseline Ready" "Metric Scraped" "CLF Not Ready" "Metric False=1" "Alert Firing" "Cleanup" "Alert Resolved"; do
    status="${RESULTS[$test_name]:-N/A}"
    case $status in
        PASS) color="${GREEN}" ;;
        FAIL) color="${RED}" ;;
        SKIP) color="${YELLOW}" ;;
        INFO) color="${CYAN}" ;;
        *)    color="${NC}" ;;
    esac
    printf "  │ %-26s │ ${color}%-8s${NC} │\n" "$test_name" "$status"
done

echo -e "  └────────────────────────────┴──────────┘"
echo ""

if [ $TOTAL_FAIL -eq 0 ]; then
    echo -e "  ${BG_GREEN}${WHITE}${BOLD}  OVERALL: TEST PASSED  ${NC}"
else
    echo -e "  ${BG_RED}${WHITE}${BOLD}  OVERALL: TEST FAILED (${TOTAL_FAIL} failures)  ${NC}"
fi

echo ""
echo -e "  ${CYAN}Done. Thank you for testing!${NC}"
echo ""

# Exit with appropriate code
if [ $TOTAL_FAIL -gt 0 ]; then
    exit 1
fi
exit 0
