#!/bin/bash
###############################################################################
# env_check.sh - Generic software environment checker
#                (runs directly on any Linux host / container)
#
# Purpose:
#   Check the current software environment item by item (interpreters / pip
#   packages / system packages / CA certificates / Ascend CANN / NPU, etc.)
#   and emit a unified [PASS|FAIL|INFO] report. Exit code is 1 when any FAIL
#   occurs, so the script can act as an environment gate.
#
# Usage:
#   1) Check the current environment (enter the container/host first):
#        bash env_check.sh
#   2) One-shot check of a given image (no container left behind, script via
#      stdin):
#        docker run --rm -i <image> bash -s < env_check.sh
#        e.g.: docker run --rm -i quay.io/ascend/vllm-ascend:v0.23.0-openeuler bash -s < env_check.sh
#   3) Run only selected items (--step convention matches the sibling model
#      script set):
#        bash env_check.sh --step python,lmcache
#
# Extending (touch only two places):
#   1) Add an id to CHECK_LIST (position = output order).
#   2) Implement the matching check_<id>() function (report under the same id).
#
# Notes:
#   On some images (e.g. Ascend) the CANN environment is only set by the
#   entrypoint/profile; when running as a non-login shell the script sources
#   common env scripts as a fallback.
###############################################################################

set -o pipefail
export LC_ALL=C

# ===== Check list (add/remove freely; position = output order) =====
CHECK_LIST=(python pip ca_certs vllm vllm_ascend modelslim lmcache guidellm cann npu)

# ===== Result counters =====
PASS=0
FAIL=0
INFO=0

# ===== Output colors (auto-disabled on non-TTY or when NO_COLOR is set,
#       so pipes / logs stay clean) =====
setup_colors() {
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[33m'; C_RESET=$'\033[0m'
    else
        C_PASS=""; C_FAIL=""; C_INFO=""; C_RESET=""
    fi
}

# report <item> <PASS|FAIL|INFO> <details...>
report() {
    local item="$1" status="$2" color
    shift 2
    case "$status" in
        PASS) color="$C_PASS"; PASS=$((PASS + 1)) ;;
        FAIL) color="$C_FAIL"; FAIL=$((FAIL + 1)) ;;
        *)    color="$C_INFO"; INFO=$((INFO + 1)) ;;
    esac
    printf '[%s%-4s%s] %-14s %s\n' "$color" "$status" "$C_RESET" "$item" "$*"
}

# ===== Generic helpers =====

# Locate a Python interpreter (prefer python3); print path; return 1 if none.
find_python() {
    local c
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1; then
            command -v "$c"
            return 0
        fi
    done
    return 1
}

# Snapshot of all installed pip package versions (importlib.metadata). One
# interpreter startup covers every check item; only metadata is read, modules
# are NOT imported, to avoid loading heavy deps like torch (tens of seconds).
PIP_ALL=""
pip_all() {
    [ -n "$PIP_ALL" ] && return 0
    local py
    py=$(find_python) || return 1
    PIP_ALL=$("$py" -c '
import importlib.metadata as md
for d in md.distributions():
    n = d.metadata["Name"]
    if n:
        print("%s==%s" % (n, d.version))
' 2>/dev/null)
    [ -n "$PIP_ALL" ]
}

# PEP 503 package name normalization: case-insensitive, -/_/. are equivalent.
norm_key() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '[-_.]' '-'
}

# Print installed version of a pip package (empty if not installed).
pip_version() {
    pip_all || return 1
    local k
    k=$(norm_key "$1")
    printf '%s\n' "$PIP_ALL" | awk -F'==' -v k="$k" \
        '{ gsub(/[-_.]/, "-", $1); if (tolower($1) == k) { print $2; exit } }'
}

# Print version of an importable Python module (empty if not importable).
py_mod_version() {
    local py
    py=$(find_python) || return 1
    "$py" -c '
import importlib, importlib.util, sys
name = sys.argv[1]
if importlib.util.find_spec(name) is None:
    sys.exit(1)
try:
    m = importlib.import_module(name)
except Exception:
    sys.exit(2)
print(getattr(m, "__version__", "importable (no __version__)"))
' "$1" 2>/dev/null
}

# Generic system package check: check_os_pkg <item> <package> (rpm/dpkg aware).
check_os_pkg() {
    local item="$1" pkg="$2"
    if command -v rpm >/dev/null 2>&1; then
        if rpm -q "$pkg" >/dev/null 2>&1; then
            report "$item" PASS "$(rpm -q "$pkg")"
        else
            report "$item" FAIL "rpm: $pkg not installed"
        fi
    elif command -v dpkg >/dev/null 2>&1; then
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            report "$item" PASS "dpkg: $(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
        else
            report "$item" FAIL "dpkg: $pkg not installed"
        fi
    else
        report "$item" INFO "no rpm/dpkg found, cannot check system package $pkg"
    fi
}

# Generic Python package check: check_py_pkg <item> <pip name> [import module]
# By default only pip metadata is queried (fast; a single interpreter startup
# for the whole script). Pass --import via DO_IMPORT to actually import the
# module (slow, but catches "pip present but import fails" breakage).
check_py_pkg() {
    local item="$1" pip_name="$2" mod_name="${3:-}"
    local v
    v=$(pip_version "$pip_name")
    if [ -n "$v" ]; then
        if [ -n "$mod_name" ] && [ "$DO_IMPORT" -eq 1 ]; then
            if v=$(py_mod_version "$mod_name"); then
                report "$item" PASS "pip $pip_name==$v, import $mod_name OK ($v)"
            else
                report "$item" FAIL "pip $pip_name==$v installed but import $mod_name failed (deps may be broken)"
            fi
        else
            report "$item" PASS "pip $pip_name==$v"
        fi
    elif [ -n "$mod_name" ] && [ "$DO_IMPORT" -eq 1 ]; then
        if v=$(py_mod_version "$mod_name"); then
            report "$item" PASS "import $mod_name OK (version: $v; no pip metadata)"
        else
            report "$item" FAIL "not found (pip: $pip_name / import: $mod_name)"
        fi
    else
        report "$item" FAIL "not found (pip: $pip_name)"
    fi
}

# ===== Check implementations (one-to-one with CHECK_LIST) =====

check_python() {
    local py
    if py=$(find_python); then
        report python PASS "$("$py" -V 2>&1) ($py)"
    else
        report python FAIL "no python3/python interpreter found"
    fi
}

check_pip() {
    local py v
    if ! py=$(find_python); then
        report pip FAIL "no interpreter, cannot check pip"
        return 0
    fi
    if v=$("$py" -m pip -V 2>/dev/null); then
        report pip PASS "$v"
    else
        report pip FAIL "pip module unavailable"
    fi
}

# ca-certificates system package + actual certificate bundle file.
check_ca_certs() {
    check_os_pkg ca_certs ca-certificates
    local bundle
    for bundle in /etc/pki/openssl-ca-bundle/ca-bundle.crt \
                   /etc/pki/tls/certs/ca-bundle.crt \
                   /etc/ssl/certs/ca-certificates.crt; do
        if [ -s "$bundle" ]; then
            report ca_certs INFO "bundle: $bundle ($(grep -c '^-----BEGIN CERT' "$bundle") certs)"
            break
        fi
    done
}

check_vllm()        { check_py_pkg vllm vllm vllm; }
check_vllm_ascend() { check_py_pkg vllm_ascend vllm-ascend vllm_ascend; }
check_modelslim()   { check_py_pkg modelslim ModelSlim modelslim; }
check_lmcache()     { check_py_pkg lmcache lmcache lmcache; }
check_guidellm()    { check_py_pkg guidellm guidellm guidellm; }

# Ascend CANN toolkit (the "latest" symlink resolves to the version; CANN 9.x
# layout falls back to the "cann" link).
check_cann() {
    local base="/usr/local/Ascend" latest
    latest=$(readlink -f "$base/ascend-toolkit/latest" 2>/dev/null)
    { [ -n "$latest" ] && [ -d "$latest" ]; } || latest=$(readlink -f "$base/cann" 2>/dev/null)
    if [ -n "$latest" ] && [ -d "$latest" ]; then
        report cann PASS "toolkit: $latest"
    else
        report cann FAIL "not found ($base/ascend-toolkit/latest)"
    fi
}

# NPU device (npu-smi tool + /dev/davinci<N> nodes;
# /dev/davinci_manager is a driver management node and is NOT counted as an
# NPU; CANN 9.x runtime images no longer ship npu-smi, so device nodes act as
# a fallback signal; a bare `docker run` without NPU passthrough legitimately
# has no device nodes -> report INFO, not FAIL).
check_npu() {
    local npu_bin nodes="" n=0 d
    npu_bin=$(command -v npu-smi 2>/dev/null)
    [ -n "$npu_bin" ] || npu_bin=$(find /usr/local/Ascend -maxdepth 5 -name npu-smi -type f 2>/dev/null | head -n 1)
    # Match only /dev/davinci<number>, excluding /dev/davinci_manager
    for d in /dev/davinci[0-9]*; do
        [ -e "$d" ] || continue
        nodes="${nodes:+$nodes }$d"
        n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then
        report npu PASS "$n NPU device node(s) visible ($nodes)${npu_bin:+; npu-smi: $npu_bin}"
    elif [ -n "$npu_bin" ]; then
        report npu INFO "npu-smi: $npu_bin, but no /dev/davinci<N> nodes (NPU not passed through to container)"
    else
        report npu INFO "no npu-smi (removed in newer CANN), and no /dev/davinci<N> nodes (NPU not passed through to container)"
    fi
}

# ===== Argument parsing (--step convention matches the sibling model
#       script set) =====
WANT=()      # selected items; empty = run all
DO_IMPORT=0  # 1 = additionally verify Python modules via real import (slow)

usage() {
    cat <<EOF
Usage: $0 [--step <id1,id2,...>] [--import]

Check items (output order): ${CHECK_LIST[*]}

  --step <ids>      Run only the specified items (comma-separated, order-independent),
                    e.g. --step python,lmcache
  --import          Additionally verify Python modules via real import (catches
                    "pip present but import fails" breakage; loads heavy deps
                    like torch, noticeably slower; off by default)
  -h, --help        Show this help

Exit code: 0 = no FAIL; 1 = at least one FAIL; 2 = argument error
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --step)
                [ "$#" -ge 2 ] || { echo "Error: --step requires an argument" >&2; exit 2; }
                IFS=',' read -ra WANT <<< "$2"
                shift 2
                ;;
            --step=*)
                IFS=',' read -ra WANT <<< "${1#--step=}"
                shift
                ;;
            --import)
                DO_IMPORT=1
                shift
                ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                echo "Error: unknown argument $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
    local w
    [ "${#WANT[@]}" -gt 0 ] || return 0
    for w in "${WANT[@]}"; do
        case " ${CHECK_LIST[*]} " in
            *" $w "*) ;;
            *) echo "Error: unknown check item $w (available: ${CHECK_LIST[*]})" >&2; exit 2 ;;
        esac
    done
}

# ===== Main logic =====

# Minimal containers may lack the hostname command; fall back to /proc.
host_name() {
    hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown-host
}

# Fallback: on some images the CANN environment is only set by the
# entrypoint/profile; when running as a non-login shell, source common env
# scripts manually (dedupe by realpath).
load_ascend_env() {
    local f r sourced=""
    for f in /usr/local/Ascend/ascend-toolkit/latest/set_env.sh \
             /usr/local/Ascend/ascend-toolkit/latest/bin/set_env.sh \
             /usr/local/Ascend/cann*/set_env.sh \
             /usr/local/Ascend/ascend-toolkit/set_env.sh \
             /etc/profile.d/ascend.sh; do
        [ -r "$f" ] || continue
        r=$(readlink -f "$f" 2>/dev/null || echo "$f")
        case " $sourced " in
            *" $r "*) continue ;;
        esac
        sourced="$sourced $r"
        # shellcheck disable=SC1090
        . "$f" 2>/dev/null
    done
}

print_header() {
    echo "============================================================"
    echo " Software Environment Check  $(host_name)  $(date '+%F %T')"
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release && echo " OS: ${PRETTY_NAME:-unknown}"
    fi
    echo "============================================================"
}

run_checks() {
    local id w want
    for id in "${CHECK_LIST[@]}"; do
        if [ "${#WANT[@]}" -gt 0 ]; then
            want=0
            for w in "${WANT[@]}"; do
                [ "$w" = "$id" ] && want=1
            done
            [ "$want" -eq 1 ] || continue
        fi
        if ! declare -F "check_$id" >/dev/null; then
            report "$id" FAIL "check function check_$id not implemented"
            continue
        fi
        "check_$id"
    done
}

# Return value = environment gate (0 = no FAIL).
print_summary() {
    echo "------------------------------------------------------------"
    echo "Summary: ${C_PASS}PASS=$PASS${C_RESET} ${C_FAIL}FAIL=$FAIL${C_RESET} ${C_INFO}INFO=$INFO${C_RESET}"
    [ "$FAIL" -eq 0 ]
}

main() {
    setup_colors
    parse_args "$@"
    load_ascend_env
    print_header
    run_checks
    print_summary
}

main "$@"
