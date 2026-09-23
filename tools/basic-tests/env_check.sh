#!/bin/bash
###############################################################################
# env_check.sh - 通用软件环境检查脚本（任意 Linux 主机/容器内直接运行）
#
# 功能:
#   逐项检查当前环境的软件环境（解释器/pip 包/系统包/证书/昇腾 CANN/NPU 等），
#   输出统一的 [PASS|FAIL|INFO] 报告；有 FAIL 时退出码为 1，可作环境门禁。
#
# 使用:
#   1) 检查当前环境（先进容器/主机再执行）:
#        bash env_check.sh
#   2) 一次性检查指定镜像（不留容器，脚本走 stdin）:
#        docker run --rm -i <image> bash -s < env_check.sh
#        例: docker run --rm -i quay.io/ascend/vllm-ascend:v0.23.0-openeuler bash -s < env_check.sh
#   3) 只跑指定项（--step 约定与同目录模型脚本集一致）:
#        bash env_check.sh --step python,lmcache
#
# 扩展检查项（只改两处）:
#   1) CHECK_LIST 里加一个 id（位置 = 输出顺序）
#   2) 实现对应 check_<id>() 函数（内部用 report 以同名 id 上报）
#
# 说明: 部分镜像（如昇腾）的 CANN 环境只由 entrypoint/profile 设置，
#       非 login shell 下运行时脚本会自动 source 常见 env 脚本兜底。
###############################################################################

set -o pipefail
export LC_ALL=C

# ===== 检查项清单（可自由增删，位置即输出顺序） =====
CHECK_LIST=(python pip ca_certs vllm vllm_ascend modelslim lmcache guidellm cann npu)

# ===== 结果统计 =====
PASS=0
FAIL=0
INFO=0

# ===== 输出颜色（非 TTY 或设置 NO_COLOR 时自动关闭，保证管道/日志干净） =====
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_PASS=$'\033[32m' C_FAIL=$'\033[31m' C_INFO=$'\033[33m' C_RESET=$'\033[0m'
else
    C_PASS="" C_FAIL="" C_INFO="" C_RESET=""
fi

# report <项> <PASS|FAIL|INFO> <详情...>
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

# ===== 通用 helper =====

# 找 Python 解释器（优先 python3），输出路径；找不到返回 1
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

# 所有 pip 包版本快照（importlib.metadata，一次解释器启动覆盖全部检查项；
# 只读元数据不 import 模块，避免加载 torch 等重型依赖导致单包耗时数十秒）
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

# PEP 503 包名归一: 忽略大小写，-/_/. 等价
norm_key() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '[-_.]' '-'
}

# 输出 pip 包已安装版本（未安装输出空）
pip_version() {
    pip_all || return 1
    local k
    k=$(norm_key "$1")
    printf '%s\n' "$PIP_ALL" | awk -F'==' -v k="$k" \
        '{ gsub(/[-_.]/, "-", $1); if (tolower($1) == k) { print $2; exit } }'
}

# 输出可 import 的 Python 模块版本（不可 import 输出空）
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

# 系统包通用检查: check_os_pkg <项> <包名>（自动适配 rpm/dpkg）
check_os_pkg() {
    local item="$1" pkg="$2"
    if command -v rpm >/dev/null 2>&1; then
        if rpm -q "$pkg" >/dev/null 2>&1; then
            report "$item" PASS "$(rpm -q "$pkg")"
        else
            report "$item" FAIL "rpm: $pkg 未安装"
        fi
    elif command -v dpkg >/dev/null 2>&1; then
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            report "$item" PASS "dpkg: $(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
        else
            report "$item" FAIL "dpkg: $pkg 未安装"
        fi
    else
        report "$item" INFO "无 rpm/dpkg，无法检查系统包 $pkg"
    fi
}

# Python 包通用检查: check_py_pkg <项> <pip 包名> [import 模块名]
# 默认只查 pip 元数据（快，全脚本仅一次解释器启动）；
# 加 --import 才真实 import（慢，可抓出"pip 在但 import 失败"的损坏安装）
check_py_pkg() {
    local item="$1" pip_name="$2" mod_name="${3:-}"
    local v
    v=$(pip_version "$pip_name")
    if [ -n "$v" ]; then
        if [ -n "$mod_name" ] && [ "$DO_IMPORT" -eq 1 ]; then
            if v=$(py_mod_version "$mod_name"); then
                report "$item" PASS "pip $pip_name==$v，import $mod_name 成功（$v）"
            else
                report "$item" FAIL "pip $pip_name==$v 已装但 import $mod_name 失败（依赖可能损坏）"
            fi
        else
            report "$item" PASS "pip $pip_name==$v"
        fi
    elif [ -n "$mod_name" ] && [ "$DO_IMPORT" -eq 1 ]; then
        if v=$(py_mod_version "$mod_name"); then
            report "$item" PASS "import $mod_name 成功（版本: $v；无 pip 元数据）"
        else
            report "$item" FAIL "未找到（pip: $pip_name / import: $mod_name）"
        fi
    else
        report "$item" FAIL "未找到（pip: $pip_name）"
    fi
}

# ===== 检查项实现（与 CHECK_LIST 一一对应） =====

check_python() {
    local py
    if py=$(find_python); then
        report python PASS "$("$py" -V 2>&1) ($py)"
    else
        report python FAIL "无 python3/python 解释器"
    fi
}

check_pip() {
    local py v
    if ! py=$(find_python); then
        report pip FAIL "无解释器，无法检查 pip"
        return 0
    fi
    if v=$("$py" -m pip -V 2>/dev/null); then
        report pip PASS "$v"
    else
        report pip FAIL "pip 模块不可用"
    fi
}

# ca-certificates 系统包 + 实际证书包文件
check_ca_certs() {
    check_os_pkg ca_certs ca-certificates
    local bundle
    for bundle in /etc/pki/openssl-ca-bundle/ca-bundle.crt \
                   /etc/pki/tls/certs/ca-bundle.crt \
                   /etc/ssl/certs/ca-certificates.crt; do
        if [ -s "$bundle" ]; then
            report ca_certs INFO "证书包: $bundle（$(grep -c '^-----BEGIN CERT' "$bundle") 张证书）"
            break
        fi
    done
}

check_vllm()        { check_py_pkg vllm vllm vllm; }
check_vllm_ascend() { check_py_pkg vllm_ascend vllm-ascend vllm_ascend; }
check_modelslim()   { check_py_pkg modelslim ModelSlim modelslim; }
check_lmcache()     { check_py_pkg lmcache lmcache lmcache; }
check_guidellm()    { check_py_pkg guidellm guidellm guidellm; }

# 昇腾 CANN toolkit（latest 符号链接即版本号；CANN 9.x 布局回退到 cann 链接）
check_cann() {
    local base="/usr/local/Ascend" latest
    latest=$(readlink -f "$base/ascend-toolkit/latest" 2>/dev/null)
    { [ -n "$latest" ] && [ -d "$latest" ]; } || latest=$(readlink -f "$base/cann" 2>/dev/null)
    if [ -n "$latest" ] && [ -d "$latest" ]; then
        report cann PASS "toolkit: $latest"
    else
        report cann FAIL "未找到（$base/ascend-toolkit/latest）"
    fi
}

# NPU 设备（npu-smi 工具 + /dev/davinci<N> 设备节点；
# /dev/davinci_manager 是驱动管理节点，不计入 NPU；
# CANN 9.x 运行时镜像不再自带 npu-smi，设备节点作为兜底信号；
# 裸 docker run 无 NPU 透传时设备节点为空属正常，报 INFO 不算 FAIL）
check_npu() {
    local npu_bin nodes="" n=0
    npu_bin=$(command -v npu-smi 2>/dev/null)
    [ -n "$npu_bin" ] || npu_bin=$(find /usr/local/Ascend -maxdepth 5 -name npu-smi -type f 2>/dev/null | head -n 1)
    # 只匹配 /dev/davinci<数字>，排除 /dev/davinci_manager
    for d in /dev/davinci[0-9]*; do
        [ -e "$d" ] || continue
        nodes="${nodes:+$nodes }$d"
        n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then
        report npu PASS "可见 $n 个 NPU 设备节点（$nodes）${npu_bin:+；npu-smi: $npu_bin}"
    elif [ -n "$npu_bin" ]; then
        report npu INFO "npu-smi: $npu_bin，但无 /dev/davinci<N> 设备节点（容器未透传 NPU）"
    else
        report npu INFO "无 npu-smi（新版 CANN 已移除），且无 /dev/davinci<N> 设备节点（容器未透传 NPU）"
    fi
}

# ===== 参数解析（--step 约定与同目录模型脚本集一致） =====
WANT=()      # 指定项，空 = 全跑
DO_IMPORT=0  # 1 = 对 Python 模块追加真实 import 校验（慢）

usage() {
    cat <<EOF
用法: $0 [--step <id1,id2,...>] [--import]

检查项（输出顺序）: ${CHECK_LIST[*]}

  --step <id列表>   只跑指定项（逗号分隔、顺序无关），如 --step python,lmcache
  --import          对 Python 模块追加真实 import 校验（可抓出"pip 在但 import 失败"
                    的损坏安装；实际加载 torch 等重型依赖，明显变慢，默认关闭）
  -h, --help        显示本帮助

退出码: 0=无 FAIL；1=有 FAIL；2=参数错误
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --step)
                [ "$#" -ge 2 ] || { echo "错误: --step 需要参数" >&2; exit 2; }
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
                echo "错误: 未知参数 $1" >&2
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
            *) echo "错误: 未知检查项 $w（可用: ${CHECK_LIST[*]}）" >&2; exit 2 ;;
        esac
    done
}

# ===== 主逻辑 =====

# 精简容器可能没有 hostname 命令，回退到 /proc
host_name() {
    hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown-host
}

# 兜底: 部分镜像的 CANN 环境只在 entrypoint/profile 里设置，
# 非 login shell 运行时手动 source 常见 env 脚本（按 realpath 去重）
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
    echo " 软件环境检查  $(host_name)  $(date '+%F %T')"
    [ -r /etc/os-release ] && . /etc/os-release && echo " OS: ${PRETTY_NAME:-未知}"
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
            report "$id" FAIL "未实现检查函数 check_$id"
            continue
        fi
        "check_$id"
    done
}

# 返回值 = 环境门禁（0=无 FAIL）
print_summary() {
    echo "------------------------------------------------------------"
    echo "汇总: ${C_PASS}PASS=$PASS${C_RESET} ${C_FAIL}FAIL=$FAIL${C_RESET} ${C_INFO}INFO=$INFO${C_RESET}"
    [ "$FAIL" -eq 0 ]
}

main() {
    parse_args "$@"
    load_ascend_env
    print_header
    run_checks
    print_summary
}

main "$@"
