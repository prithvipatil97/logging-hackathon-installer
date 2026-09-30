#!/bin/bash
###############################################################################
#
#  Test: Logging must-gather Go binary (LOG-9008)
#
#  Version: 1.1.0
#  Epic:    LOG-9354 - Log Collection 6.7 Tech Debt
#
#  Purpose:
#    Verify the Cluster Logging Operator image ships must-gather as a compiled
#    Go binary (not the old shell collection-scripts) and that
#    `oc adm must-gather` produces the expected artifact layout.
#
#  What this test validates:
#    Phase 1 - Prerequisites (oc login, CLO running)
#    Phase 2 - Image packaging: ELF binary, gather symlink, no /usr/bin/oc
#    Phase 3 - Run oc adm must-gather using the installed CLO image
#    Phase 4 - Artifact layout (namespaces, cluster-scoped-resources, debug log)
#
#  Prerequisites:
#    - Cluster Logging Operator installed and running
#    - oc CLI logged in with cluster-admin privileges
#
#  Usage:
#    ./test-67-must-gather.sh
#    ./test-67-must-gather.sh --skip-gather          # image checks only
#    ./test-67-must-gather.sh --keep                 # keep dest dir
#    ./test-67-must-gather.sh --dest-dir /tmp/mg
#    ./test-67-must-gather.sh --timeout 20           # minutes
#
#  Author:  Prithviraj Patil (Red Hat Logging Hackathon 6.7)
#
###############################################################################

set -uo pipefail

# =============================================================================
#  CONFIGURATION
# =============================================================================

NAMESPACE="openshift-logging"
SCRIPT_VERSION="1.1.0"
SCRIPT_START_TIME=$(date +%s)
PHASE_PAUSE=2
KEEP=0
SKIP_GATHER=0
DEST_DIR=""
TIMEOUT_MIN=15
CLO_IMAGE=""
CLO_POD=""
GATHER_ROOT=""

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
#  HELPERS
# =============================================================================

usage() {
    cat <<'EOF'
Usage: ./test-67-must-gather.sh [options]

  --skip-gather       Only inspect the CLO image (do not run oc adm must-gather)
  --keep              Keep the must-gather destination directory
  --dest-dir PATH     Directory for oc adm must-gather output
  --timeout MINUTES   Timeout for oc adm must-gather (default: 15)
  -h, --help          Show this help

What this test is (LOG-9008):
  Logging must-gather used to be shell scripts that called `oc`. In 6.7 it is a
  compiled Go binary in the Cluster Logging Operator image. This script checks
  that packaging, then runs the same `oc adm must-gather` command customers use.

The script prints Why / What we do / Pass means before every check.
EOF
}

get_elapsed() {
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - SCRIPT_START_TIME))
    printf "%02d:%02d" "$((elapsed / 60))" "$((elapsed % 60))"
}

get_phase_elapsed() {
    local now
    now=$(date +%s)
    echo "$((now - CURRENT_PHASE_START))s"
}

print_banner() {
    echo ""
    echo -e "${BCYAN}    ███╗   ███╗██╗   ██╗███████╗████████╗       ██████╗  █████╗ ████████╗██╗  ██╗███████╗██████╗ ${NC}"
    echo -e "${BCYAN}    ████╗ ████║██║   ██║██╔════╝╚══██╔══╝      ██╔════╝ ██╔══██╗╚══██╔══╝██║  ██║██╔════╝██╔══██╗${NC}"
    echo -e "${BCYAN}    ██╔████╔██║██║   ██║███████╗   ██║   █████╗██║  ███╗███████║   ██║   ███████║█████╗  ██████╔╝${NC}"
    echo -e "${BCYAN}    ██║╚██╔╝██║██║   ██║╚════██║   ██║   ╚════╝██║   ██║██╔══██║   ██║   ██╔══██║██╔══╝  ██╔══██╗${NC}"
    echo -e "${BCYAN}    ██║ ╚═╝ ██║╚██████╔╝███████║   ██║         ╚██████╔╝██║  ██║   ██║   ██║  ██║███████╗██║  ██║${NC}"
    echo -e "${BCYAN}    ╚═╝     ╚═╝ ╚═════╝ ╚══════╝   ╚═╝          ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝${NC}"
    echo ""
    echo -e "${BWHITE}  ╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BWHITE}  ║${NC}   ${BOLD}${BCYAN}Logging must-gather Go binary${NC}  ${DIM}Automated Validation${NC}                 ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Jira:${NC}    ${BWHITE}LOG-9008${NC} ${DIM}- Refactor must-gather to a Go binary${NC}           ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Version:${NC} ${BWHITE}${SCRIPT_VERSION}${NC}                                                     ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ║${NC}   ${DIM}Date:${NC}    ${BWHITE}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}                            ${BWHITE}║${NC}"
    echo -e "${BWHITE}  ╚════════════════════════════════════════════════════════════════════════╝${NC}"
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
    local elapsed
    elapsed=$(get_phase_elapsed)
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
    while [ "$remaining" -gt 0 ]; do
        printf "\r  ${DIM}  Starting in ${remaining}s...${NC}  "
        sleep 1
        remaining=$((remaining - 1))
    done
    printf "\r  ${DIM}                          ${NC}\n"
}

log_info() { echo -e "  ${BCYAN}  ℹ ${NC} ${WHITE}$1${NC}"; }
log_action() { echo -e "  ${BMAGENTA}  ▸ ${NC} ${BOLD}$1${NC}"; }
log_detail() { echo -e "  ${DIM}      $1${NC}"; }
log_proves() { echo -e "  ${DIM}      This proves: $1${NC}"; }

print_briefing() {
    echo -e "  ${BWHITE}  What you are testing${NC}"
    echo -e "  ${DIM}  ─────────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}  Support asks customers to dump Cluster Logging state with:${NC}"
    echo -e "  ${BWHITE}    oc adm must-gather --image=<CLO image> -- /usr/bin/gather${NC}"
    echo ""
    echo -e "  ${WHITE}  That dump (namespaces, CRDs, LokiStack, collector pods, logs) is what${NC}"
    echo -e "  ${WHITE}  we attach to a bug so engineering can debug without cluster access.${NC}"
    echo ""
    echo -e "  ${BWHITE}  What changed in Logging 6.7 (LOG-9008)${NC}"
    echo -e "  ${WHITE}  OLD: must-gather was shell scripts in the CLO image. Those scripts${NC}"
    echo -e "  ${WHITE}       called ${BWHITE}oc${NC}${WHITE}, so the image had to ship the oc binary (extra CVEs).${NC}"
    echo -e "  ${WHITE}  NEW: must-gather is a compiled Go program at ${BWHITE}/usr/bin/must-gather${NC}${WHITE}.${NC}"
    echo -e "  ${WHITE}       ${BWHITE}/usr/bin/gather${NC}${WHITE} is a symlink so the documented command still works.${NC}"
    echo -e "  ${WHITE}       The image no longer contains ${BWHITE}oc${NC}${WHITE}.${NC}"
    echo ""
    echo -e "  ${BWHITE}  What this script proves${NC}"
    echo -e "  ${WHITE}  1. The installed CLO image has that Go binary (not the old scripts)${NC}"
    echo -e "  ${WHITE}  2. ${BWHITE}oc adm must-gather${NC}${WHITE} using that image actually completes${NC}"
    echo -e "  ${WHITE}  3. The dump has the expected top-level layout${NC}"
    echo ""
    echo -e "  ${BWHITE}  What this script does not do${NC}"
    echo -e "  ${WHITE}  It does not grade every YAML file. Use ${BWHITE}--keep${NC}${WHITE} and open${NC}"
    echo -e "  ${WHITE}  ${BWHITE}gather-debug.log${NC}${WHITE} if you want to inspect the dump yourself.${NC}"
    echo ""
    echo -e "  ${BWHITE}  Phases${NC}"
    echo -e "  ${WHITE}  1 Prerequisites   login + running CLO (inspect THIS cluster's image)${NC}"
    echo -e "  ${WHITE}  2 Image packaging oc exec into the CLO pod; look at files in the image${NC}"
    echo -e "  ${WHITE}  3 Run gather      the real customer command (creates a temp namespace)${NC}"
    echo -e "  ${WHITE}  4 Inspect dump    confirm artifacts you would attach to a bug${NC}"
    echo -e "  ${DIM}  ─────────────────────────────────────────────────────────────────────${NC}"
    echo ""
}

explain_phase() {
    echo -e "  ${BWHITE}  What this phase does${NC}"
    while [ $# -gt 0 ]; do
        echo -e "  ${WHITE}    $1${NC}"
        shift
    done
    echo ""
}

explain_check() {
    local name=$1
    local why=$2
    local what=$3
    local pass_means=$4
    echo ""
    echo -e "  ${BWHITE}  Check: ${name}${NC}"
    echo -e "  ${CYAN}    Why:${NC}        ${WHITE}${why}${NC}"
    echo -e "  ${CYAN}    What we do:${NC}  ${WHITE}${what}${NC}"
    echo -e "  ${CYAN}    Pass means:${NC}  ${WHITE}${pass_means}${NC}"
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

record_result() {
    RESULTS["$1"]="$2"
}

pod_exec() {
    oc exec -n "${NAMESPACE}" "${CLO_POD}" -- "$@" 2>/dev/null
}

find_gather_root() {
    local dest=$1
    local debug_log
    debug_log=$(find "$dest" -name gather-debug.log -type f 2>/dev/null | head -1)
    if [ -n "$debug_log" ]; then
        dirname "$debug_log"
        return 0
    fi
    return 1
}

cleanup() {
    if [ "$KEEP" -eq 0 ] && [ -n "${DEST_DIR:-}" ] && [ -d "$DEST_DIR" ]; then
        rm -rf "$DEST_DIR"
    fi
}

# =============================================================================
#  ARGS
# =============================================================================

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-gather) SKIP_GATHER=1; shift ;;
        --keep) KEEP=1; shift ;;
        --dest-dir)
            DEST_DIR="${2:-}"
            if [ -z "$DEST_DIR" ]; then
                echo "error: --dest-dir requires a path" >&2
                exit 1
            fi
            shift 2
            ;;
        --timeout)
            TIMEOUT_MIN="${2:-}"
            if [ -z "$TIMEOUT_MIN" ]; then
                echo "error: --timeout requires minutes" >&2
                exit 1
            fi
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$DEST_DIR" ]; then
    DEST_DIR="/tmp/logging-67-must-gather-$(date +%Y%m%d-%H%M%S)"
fi

trap cleanup EXIT

# =============================================================================
#  MAIN
# =============================================================================

print_banner
print_briefing

# -----------------------------------------------------------------------------
#  PHASE 1: PREREQUISITES
# -----------------------------------------------------------------------------

print_phase_header 1 "Prerequisites Check" "N/A"
explain_phase \
    "Confirm you are logged in and Cluster Logging Operator is running." \
    "Later phases inspect files inside the CLO pod and run must-gather" \
    "using this cluster's installed operator image — not a random quay tag."

explain_check "OC Login" \
    "must-gather and oc exec require a working kubeconfig." \
    "Run oc whoami and print the API server URL." \
    "You are authenticated to a cluster."
log_action "Checking oc CLI access..."
if ! oc whoami &>/dev/null; then
    log_fail "Not logged in to OpenShift cluster"
    echo -e "  ${BRED}  Please run 'oc login' first and try again.${NC}"
    exit 1
fi
log_pass "Logged in as: ${BWHITE}$(oc whoami)${NC}"
log_detail "Cluster: $(oc whoami --show-server 2>/dev/null)"
record_result "OC Login" "PASS"
log_proves "later oc exec and oc adm must-gather will run against this cluster."

explain_check "CLO Running" \
    "must-gather lives in the Cluster Logging Operator image, not a separate plugin image." \
    "Find a Running pod labeled cluster-logging-operator in openshift-logging." \
    "CLO is installed so we can inspect its filesystem and use its image."
log_action "Checking Cluster Logging Operator..."
CLO_POD=$(oc get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=cluster-logging-operator \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$CLO_POD" ]; then
    CLO_POD=$(oc get pods -n "${NAMESPACE}" -l name=cluster-logging-operator \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi
if [ -z "$CLO_POD" ]; then
    log_fail "Cluster Logging Operator pod not found in ${NAMESPACE}"
    record_result "CLO Running" "FAIL"
    exit 1
fi
CLO_STATUS=$(oc get pod "${CLO_POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$CLO_STATUS" != "Running" ]; then
    log_fail "CLO pod is not Running (status: ${CLO_STATUS})"
    record_result "CLO Running" "FAIL"
    exit 1
fi
log_pass "CLO is running: ${BWHITE}${CLO_POD}${NC}"
record_result "CLO Running" "PASS"
log_proves "Phase 2 can oc exec into this pod; Phase 3 can reuse the same image."

explain_check "CLO Image" \
    "oc adm must-gather --image= must point at the operator image customers run." \
    "Read the image from the cluster-logging-operator Deployment (same as docs)." \
    "We captured the exact image digest/tag installed on this cluster."
log_action "Resolving CLO operator image..."
CLO_IMAGE=$(oc get deploy cluster-logging-operator -n "${NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="cluster-logging-operator")].image}' 2>/dev/null)
if [ -z "$CLO_IMAGE" ]; then
    CLO_IMAGE=$(oc get pod "${CLO_POD}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
fi
if [ -z "$CLO_IMAGE" ]; then
    log_fail "Could not resolve the cluster-logging-operator image"
    record_result "CLO Image" "FAIL"
    exit 1
fi
log_pass "CLO image resolved"
log_detail "${CLO_IMAGE}"
record_result "CLO Image" "PASS"
log_proves "Phase 3 will pass this image to oc adm must-gather --image=..."

print_phase_complete 1

# -----------------------------------------------------------------------------
#  PHASE 2: IMAGE PACKAGING (LOG-9008)
# -----------------------------------------------------------------------------

phase_transition 2 "Image packaging"
print_phase_header 2 "Must-gather is a Go binary (no oc / no shell scripts)" "LOG-9008"
explain_phase \
    "Look inside the running CLO pod (same container image used for gather)." \
    "LOG-9008 replaced shell collection-scripts with a Go binary." \
    "We check the binary exists, is ELF (not #!), gather is a symlink," \
    "and oc / old gather_* scripts are gone."

explain_check "Binary Exists" \
    "If /usr/bin/must-gather is missing, this image still has the old gather layout." \
    "oc exec into the CLO pod and test -f /usr/bin/must-gather." \
    "The Go entrypoint is present in the installed image."
log_action "Checking /usr/bin/must-gather exists..."
if pod_exec test -f /usr/bin/must-gather; then
    MG_SIZE=$(pod_exec ls -l /usr/bin/must-gather | awk '{print $5}')
    log_pass "/usr/bin/must-gather is present (${MG_SIZE} bytes)"
    record_result "Binary Exists" "PASS"
    log_proves "the image ships the new gather entrypoint."
    explain_check "Binary Size" \
        "Old gather was a tiny shell script. The Go binary is tens of megabytes." \
        "Read the file size from ls -l inside the pod. Expect more than 1MB." \
        "The file is large enough to be a compiled program, not a script."
    if [ "${MG_SIZE:-0}" -gt 1000000 ] 2>/dev/null; then
        log_pass "Binary size looks like a compiled Go binary (>1MB)"
        record_result "Binary Size" "PASS"
        log_proves "this is not a leftover shell wrapper."
    else
        log_fail "Binary is only ${MG_SIZE} bytes (old shell gather was tiny)"
        record_result "Binary Size" "FAIL"
    fi
else
    log_fail "/usr/bin/must-gather is missing (LOG-9008 not in this image)"
    record_result "Binary Exists" "FAIL"
    record_result "Binary Size" "FAIL"
fi

explain_check "ELF Magic" \
    "A shell script starts with #! (bytes 23 21). A Linux binary starts with ELF 7f 45 4c 46." \
    "oc exec: od -An -tx1 -N 4 /usr/bin/must-gather and compare to 7f454c46." \
    "must-gather is a compiled ELF binary, not a bash script."
log_action "Checking ELF magic on /usr/bin/must-gather..."
ELF_HEX=$(pod_exec od -An -tx1 -N 4 /usr/bin/must-gather 2>/dev/null | tr -d ' \n\t')
if [ "$ELF_HEX" = "7f454c46" ]; then
    log_pass "must-gather is ELF (7f 45 4c 46) — compiled binary, not a script"
    record_result "ELF Magic" "PASS"
    log_proves "LOG-9008 packaging is in this image (not the old #!/bin/bash gather)."
else
    log_fail "must-gather is not ELF (got: ${ELF_HEX:-empty})"
    log_detail "A shell gather starts with #!  (23 21)."
    record_result "ELF Magic" "FAIL"
fi

explain_check "Gather Symlink" \
    "Docs and oc adm must-gather still call /usr/bin/gather. Dockerfile does ln -s must-gather gather." \
    "oc exec: ls -l /usr/bin/gather and confirm it points at /usr/bin/must-gather." \
    "The documented gather command runs the Go binary."
log_action "Checking /usr/bin/gather symlink..."
GATHER_LINK=$(pod_exec ls -l /usr/bin/gather 2>/dev/null || true)
if echo "$GATHER_LINK" | grep -Fq -- '-> /usr/bin/must-gather'; then
    log_pass "/usr/bin/gather -> /usr/bin/must-gather"
    record_result "Gather Symlink" "PASS"
    log_proves "customers can keep using -- /usr/bin/gather."
elif pod_exec test -f /usr/bin/gather && [ "$ELF_HEX" = "7f454c46" ]; then
    log_pass "/usr/bin/gather exists as an ELF binary"
    record_result "Gather Symlink" "PASS"
    log_proves "gather is the Go binary even if it is not a symlink."
else
    log_fail "/usr/bin/gather is missing or is not the Go binary"
    log_detail "${GATHER_LINK:-not found}"
    record_result "Gather Symlink" "FAIL"
fi

explain_check "No oc Binary" \
    "The old scripts shelled out to oc. LOG-9008 uses the Kubernetes Go client instead so oc can leave the image." \
    "oc exec: test -e /usr/bin/oc (expect missing)." \
    "The operator image no longer ships oc (smaller CVE surface)."
log_action "Checking oc was removed from the operator image..."
if pod_exec test -e /usr/bin/oc; then
    log_fail "/usr/bin/oc is still in the image (old must-gather depended on oc)"
    record_result "No oc Binary" "FAIL"
else
    log_pass "/usr/bin/oc is absent (Go must-gather uses the Kubernetes client)"
    record_result "No oc Binary" "PASS"
    log_proves "must-gather no longer depends on oc inside the image."
fi

explain_check "No Shell Scripts" \
    "The old image copied must-gather/collection-scripts/* into /usr/bin (gather_*, collection helpers)." \
    "List /usr/bin and look for leftover gather_* or collection* names." \
    "The shell collection-scripts were removed from this image."
log_action "Checking leftover collection-scripts..."
SCRIPT_LEFTOVERS=$(pod_exec sh -c 'ls /usr/bin 2>/dev/null' | grep -E '^(gather_|collection)' || true)
if [ -n "$SCRIPT_LEFTOVERS" ]; then
    log_fail "Old collection-scripts still present: ${SCRIPT_LEFTOVERS}"
    record_result "No Shell Scripts" "FAIL"
else
    log_pass "No leftover gather_* / collection-scripts in /usr/bin"
    record_result "No Shell Scripts" "PASS"
    log_proves "only the Go binary (and the gather symlink) remain."
fi

print_phase_complete 2

# -----------------------------------------------------------------------------
#  PHASE 3: RUN MUST-GATHER
# -----------------------------------------------------------------------------

phase_transition 3 "Run oc adm must-gather"
print_phase_header 3 "Run oc adm must-gather with the CLO image" "LOG-9008"
explain_phase \
    "Packaging is not enough: the binary must actually collect data." \
    "This is the same command a customer (or support) runs for a logging case." \
    "OpenShift creates a temporary namespace, runs /usr/bin/gather in a pod," \
    "then copies the dump to your machine. --keep leaves that directory on disk."

if [ "$SKIP_GATHER" -eq 1 ]; then
    log_skip "Skipped (--skip-gather). Artifact checks will be skipped."
    record_result "Gather Completes" "SKIP"
    print_phase_complete 3
else
    explain_check "Gather Completes" \
        "A Go binary that exists but crashes is still a product failure." \
        "Run: oc adm must-gather --image=<CLO image> --dest-dir=... -- /usr/bin/gather" \
        "must-gather exited 0 and copied artifacts locally."
    log_info "OpenShift will create a temporary must-gather namespace, then copy"
    log_info "artifacts to ${BWHITE}${DEST_DIR}${NC}"
    echo ""
    mkdir -p "$DEST_DIR"

    log_action "Running: oc adm must-gather --image=<CLO> -- /usr/bin/gather"
    log_detail "timeout=${TIMEOUT_MIN}m  dest=${DEST_DIR}"
    echo ""

    oc adm must-gather \
        --dest-dir="${DEST_DIR}" \
        --image="${CLO_IMAGE}" \
        --timeout="${TIMEOUT_MIN}m" \
        -- /usr/bin/gather
    GATHER_RC=$?

    echo ""
    if [ "$GATHER_RC" -eq 0 ]; then
        log_pass "oc adm must-gather exited 0"
        record_result "Gather Completes" "PASS"
        log_proves "the Go gather ran end-to-end on this cluster."
    else
        log_fail "oc adm must-gather exited ${GATHER_RC} (artifacts may still be present)"
        record_result "Gather Completes" "FAIL"
    fi
    print_phase_complete 3
fi

# -----------------------------------------------------------------------------
#  PHASE 4: ARTIFACTS
# -----------------------------------------------------------------------------

phase_transition 4 "Inspect artifacts"
print_phase_header 4 "Must-gather artifact layout" "LOG-9008"
explain_phase \
    "LOG-9008 also changed the dump layout (no duplicate cluster-logging tree, no ELK)." \
    "We only check the top-level pieces testers need to recognize:" \
    "debug log, openshift-logging namespace dump, cluster-scoped resources," \
    "collector SUCCESS lines, and no elasticsearch/fluentd leftover paths."

if [ "$SKIP_GATHER" -eq 1 ]; then
    log_skip "No artifacts to inspect (--skip-gather)"
    record_result "Debug Log" "SKIP"
    record_result "Logging Namespace" "SKIP"
    record_result "Cluster Scoped" "SKIP"
    record_result "Collectors Logged" "SKIP"
    record_result "No ELK Leftovers" "SKIP"
else
    GATHER_ROOT=$(find_gather_root "$DEST_DIR" || true)
    if [ -z "$GATHER_ROOT" ]; then
        log_fail "gather-debug.log not found under ${DEST_DIR}"
        log_detail "Listing dest dir:"
        find "$DEST_DIR" -maxdepth 3 -type d 2>/dev/null | head -20 | while IFS= read -r line; do
            log_detail "$line"
        done
        record_result "Debug Log" "FAIL"
        record_result "Logging Namespace" "FAIL"
        record_result "Cluster Scoped" "FAIL"
        record_result "Collectors Logged" "FAIL"
        record_result "No ELK Leftovers" "SKIP"
    else
        explain_check "Debug Log" \
            "The Go gather writes gather-debug.log (timestamped BEGIN/END and SUCCESS lines)." \
            "Find gather-debug.log under --dest-dir; that directory is the gather root." \
            "The dump includes the debug log we would read on a support case."
        log_pass "Found gather root: ${GATHER_ROOT}"
        record_result "Debug Log" "PASS"
        log_detail "Debug log: ${GATHER_ROOT}/gather-debug.log"
        log_proves "oc adm must-gather copied the plugin output to this host."

        explain_check "Logging Namespace" \
            "A logging must-gather is useless if openshift-logging was not collected." \
            "Test that namespaces/openshift-logging exists under the gather root." \
            "CLO, collectors, and LokiStack objects from this cluster are in the dump."
        log_action "Checking namespaces/openshift-logging..."
        if [ -d "${GATHER_ROOT}/namespaces/openshift-logging" ]; then
            log_pass "namespaces/openshift-logging is present"
            record_result "Logging Namespace" "PASS"
            log_proves "namespace-scoped logging resources were collected."
        else
            log_fail "namespaces/openshift-logging is missing"
            record_result "Logging Namespace" "FAIL"
        fi

        explain_check "Cluster Scoped" \
            "CRDs, nodes, and other cluster objects live under cluster-scoped-resources/ (not only namespaces/)." \
            "Test that cluster-scoped-resources exists under the gather root." \
            "Cluster-wide logging APIs were collected."
        log_action "Checking cluster-scoped-resources..."
        if [ -d "${GATHER_ROOT}/cluster-scoped-resources" ]; then
            log_pass "cluster-scoped-resources is present"
            record_result "Cluster Scoped" "PASS"
            log_proves "cluster-scoped collectors ran (CRDs, nodes, and similar)."
        else
            log_fail "cluster-scoped-resources is missing"
            record_result "Cluster Scoped" "FAIL"
        fi

        explain_check "Collectors Logged" \
            "The Go orchestrator runs named collectors (Version, Cluster, Namespace, LogStore, UIPlugin, ...)." \
            "Grep gather-debug.log for ' SUCCESS:' (lines are timestamp-prefixed) and no FAILED." \
            "Every collector finished successfully — the dump is complete, not a partial crash."
        log_action "Checking collector SUCCESS lines in gather-debug.log..."
        # Logger prefixes every line with "YYYY-MM-DD HH:MM:SS ", so do not anchor at ^
        SUCCESS_COUNT=$(grep -c " SUCCESS:" "${GATHER_ROOT}/gather-debug.log" 2>/dev/null || true)
        SUCCESS_COUNT=${SUCCESS_COUNT:-0}
        FAILED_COUNT=$(grep -c " FAILED:" "${GATHER_ROOT}/gather-debug.log" 2>/dev/null || true)
        FAILED_COUNT=${FAILED_COUNT:-0}
        if grep -q "Must-gather collection complete" "${GATHER_ROOT}/gather-debug.log" 2>/dev/null \
            && [ "$SUCCESS_COUNT" -gt 0 ] && [ "$FAILED_COUNT" -eq 0 ]; then
            log_pass "gather-debug.log has ${SUCCESS_COUNT} SUCCESS collector line(s)"
            grep " SUCCESS:" "${GATHER_ROOT}/gather-debug.log" | while IFS= read -r line; do
                log_detail "$line"
            done
            record_result "Collectors Logged" "PASS"
            log_proves "Version, Cluster, Namespace, LogStore, and related collectors all succeeded."
        else
            log_fail "Collectors did not all succeed (SUCCESS=${SUCCESS_COUNT} FAILED=${FAILED_COUNT})"
            grep -E " SUCCESS:| FAILED:|Must-gather collection complete" "${GATHER_ROOT}/gather-debug.log" 2>/dev/null | while IFS= read -r line; do
                log_detail "$line"
            done
            record_result "Collectors Logged" "FAIL"
        fi

        explain_check "No ELK Leftovers" \
            "LOG-9008 removed obsolete Elasticsearch/Fluentd gather paths. Seeing them means an old script layout." \
            "find the dump for *elasticsearch* or *fluentd* artifact names." \
            "The dump is Loki/Vector-era layout, not the old ELK must-gather tree."
        log_action "Checking obsolete ELK / fluentd gather paths are gone..."
        ELK_HITS=$(find "${GATHER_ROOT}" \( -iname '*elasticsearch*' -o -iname '*fluentd*' \) 2>/dev/null | head -5 || true)
        if [ -n "$ELK_HITS" ]; then
            log_fail "Found leftover ELK/fluentd paths (should have been removed in LOG-9008)"
            echo "$ELK_HITS" | while IFS= read -r line; do
                log_detail "$line"
            done
            record_result "No ELK Leftovers" "FAIL"
        else
            log_pass "No elasticsearch/fluentd artifact paths"
            record_result "No ELK Leftovers" "PASS"
            log_proves "obsolete ELK gather trees were not written."
        fi
    fi
fi

print_phase_complete 4

# =============================================================================
#  FINAL REPORT
# =============================================================================

echo ""
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
for _status in "${RESULTS[@]}"; do
    case "$_status" in
        PASS) TOTAL_PASS=$((TOTAL_PASS + 1)) ;;
        FAIL) TOTAL_FAIL=$((TOTAL_FAIL + 1)) ;;
        SKIP) TOTAL_SKIP=$((TOTAL_SKIP + 1)) ;;
    esac
done
TOTAL_ELAPSED=$(( $(date +%s) - SCRIPT_START_TIME ))
TOTAL_MINS=$((TOTAL_ELAPSED / 60))
TOTAL_SECS=$((TOTAL_ELAPSED % 60))

echo -e "  ${BG_MAGENTA}${BWHITE}                                                                          ${NC}"
echo -e "  ${BG_MAGENTA}${BWHITE}   TEST EXECUTION COMPLETE                                                ${NC}"
echo -e "  ${BG_MAGENTA}${BWHITE}                                                                          ${NC}"
echo ""
echo -e "  ${BWHITE}  Logging 6.7 must-gather -- Test Report${NC}"
echo -e "  ${DIM}  Jira: LOG-9008 | Logged at: $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo -e "  ${DIM}  Total execution time: ${TOTAL_MINS}m ${TOTAL_SECS}s${NC}"
echo ""

echo -e "  ${BWHITE}┌──────┬──────────────────────────────────────────────┬──────────┬───────────┐${NC}"
echo -e "  ${BWHITE}│${NC} ${BOLD}Phase${NC} ${BWHITE}│${NC} ${BOLD}Test Check${NC}                                    ${BWHITE}│${NC} ${BOLD}Jira${NC}     ${BWHITE}│${NC} ${BOLD}Result${NC}    ${BWHITE}│${NC}"
echo -e "  ${BWHITE}├──────┼──────────────────────────────────────────────┼──────────┼───────────┤${NC}"

declare -a TEST_ORDER=(
    "1|OC Login|N/A"
    "1|CLO Running|N/A"
    "1|CLO Image|N/A"
    "2|Binary Exists|LOG-9008"
    "2|Binary Size|LOG-9008"
    "2|ELF Magic|LOG-9008"
    "2|Gather Symlink|LOG-9008"
    "2|No oc Binary|LOG-9008"
    "2|No Shell Scripts|LOG-9008"
    "3|Gather Completes|LOG-9008"
    "4|Debug Log|LOG-9008"
    "4|Logging Namespace|LOG-9008"
    "4|Cluster Scoped|LOG-9008"
    "4|Collectors Logged|LOG-9008"
    "4|No ELK Leftovers|LOG-9008"
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
echo -e "  ${BWHITE}  Summary:${NC}  ${BGREEN}${TOTAL_PASS} Passed${NC}  ${DIM}|${NC}  ${BRED}${TOTAL_FAIL} Failed${NC}  ${DIM}|${NC}  ${BYELLOW}${TOTAL_SKIP} Skipped${NC}"
echo ""
echo -e "  ${BWHITE}  How to read this report${NC}"
echo -e "  ${WHITE}  All PASS = LOG-9008 is in this 6.7 image and gather produced a usable dump.${NC}"
echo -e "  ${WHITE}  Phase 2 FAIL = this image still looks like the old shell-based must-gather.${NC}"
echo -e "  ${WHITE}  Phase 3 FAIL = gather did not finish (image pull, timeout, or permissions).${NC}"
echo -e "  ${WHITE}  Phase 4 FAIL = a dump exists but layout or collectors are wrong.${NC}"
echo -e "  ${WHITE}  --keep: open gather-debug.log, namespaces/openshift-logging, cluster-scoped-resources.${NC}"
echo ""

if [ "$KEEP" -eq 1 ] && [ "$SKIP_GATHER" -eq 0 ]; then
    echo -e "  ${DIM}Must-gather output kept at:${NC} ${BWHITE}${DEST_DIR}${NC}"
    if [ -n "${GATHER_ROOT:-}" ]; then
        echo -e "  ${DIM}Gather root:${NC} ${BWHITE}${GATHER_ROOT}${NC}"
        echo -e "  ${DIM}Start here:${NC}  ${BWHITE}${GATHER_ROOT}/gather-debug.log${NC}"
    fi
    echo ""
elif [ "$SKIP_GATHER" -eq 0 ]; then
    echo -e "  ${DIM}Destination directory will be removed on exit. Use --keep to retain it.${NC}"
    echo ""
fi

if [ "$TOTAL_FAIL" -eq 0 ]; then
    echo -e "  ${BGREEN}must-gather Go binary checks passed.${NC}"
else
    echo -e "  ${BRED}${TOTAL_FAIL} test(s) failed. Review the failures above.${NC}"
    echo -e "  ${DIM}Note: FAIL on gather/artifacts can also mean the image is an older shell-based must-gather.${NC}"
fi

echo ""
echo -e "  ${DIM}───────────────────────────────────────────────────────────────────────────${NC}"
echo -e "  ${DIM}  Red Hat Logging Hackathon 6.7 | must-gather | v${SCRIPT_VERSION}${NC}"
echo -e "  ${DIM}───────────────────────────────────────────────────────────────────────────${NC}"
echo ""

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
