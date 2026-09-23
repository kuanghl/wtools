#!/bin/bash
###############################################################################
# host_info_dump.sh - 主机信息汇总脚本
#
# 功能:
#   采集 操作系统 / 内核 / CPU / 内存 / 存储 / 网络 / 加速卡(NPU) 等信息，
#   并按 "项目,配置,说明" 三列输出 CSV。
#
# 命名约定:
#   通用采集 : collect_*
#   加速卡   : <厂商>_*   —— 昇腾 ascend_*，未来可扩展 nv_*、dcu_* 等
#
# 加速卡数据来源优先级:
#   1) ascend-dmi -i -dt   （官方诊断工具，字段结构化，首选）
#   2) npu-smi info        （次选）
#   3) lspci / version.info（兜底）
#
# 使用:
#   bash host_info_dump.sh                      # 打印到终端
#   bash host_info_dump.sh > info-host.csv      # 保存为 CSV
###############################################################################

set -o pipefail
export LC_ALL=C

# ============================================================================
# 一、通用工具
# ============================================================================
csv_field() { local v="${1:-}"; v="${v//\"/\"\"}"; printf '"%s"' "$v"; }
csv_row()   { printf '%s,%s,%s\n' "$(csv_field "$1")" "$(csv_field "$2")" "$(csv_field "$3")"; }
safe_cmd()  { "$@" 2>/dev/null || true; }
has_cmd()   { command -v "$1" >/dev/null 2>&1; }

# ============================================================================
# 二、通用采集
# ============================================================================

# 操作系统名称（不含内核）
collect_os() {
    local pretty=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        pretty="${PRETTY_NAME:-${NAME:-未知} ${VERSION:-}}"
    fi
    printf '%s' "${pretty:-未知}"
}

# 内核版本
collect_kernel() {
    safe_cmd uname -r
}

# 返回: model|cps|cps_threads|arch|sockets
#   cps         = 每座（每颗 CPU）的核数
#   cps_threads = 每座的线程数 = cps × Thread(s) per core
#   sockets     = CPU 座数
collect_cpu() {
    local model arch sockets cps tpc cps_threads total

    model="$(safe_cmd lscpu | awk -F: '/^Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
    [ -z "$model" ] && model="$(safe_cmd lscpu | awk -F: '/^BIOS Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
    [ -z "$model" ] && model="$(safe_cmd lscpu | awk -F: '/^Hardware/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"

    arch="$(safe_cmd uname -m)"
    sockets="$(safe_cmd lscpu | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}')"
    cps="$(safe_cmd lscpu | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}')"
    tpc="$(safe_cmd lscpu | awk -F: '/^Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}')"

    # socket 数兜底为 1
    [[ "$sockets" =~ ^[0-9]+$ ]] || sockets=1
    # 每核线程数兜底为 1
    [[ "$tpc" =~ ^[0-9]+$ ]] || tpc=1

    # cps 解析失败时，用 nproc / sockets 兜底
    if ! [[ "$cps" =~ ^[0-9]+$ ]]; then
        total="$(safe_cmd nproc)"
        if [[ "$total" =~ ^[0-9]+$ ]]; then
            cps=$(( total / sockets ))
        else
            cps="未知"
        fi
    fi

    if [[ "$cps" =~ ^[0-9]+$ ]]; then
        cps_threads=$(( cps * tpc ))
    else
        cps_threads="未知"
    fi

    printf '%s|%s|%s|%s|%s' \
        "${model:-未知}" "$cps" "$cps_threads" "${arch:-未知}" "$sockets"
}

# 返回: total|type
collect_memory() {
    local total type
    total="$(safe_cmd free -h | awk '/^Mem:/ {print $2}')"
    type="$(safe_cmd dmidecode -t memory \
        | awk -F: '/^[ \t]*Type:/ && $2 !~ /Unknown|Other|None/ {gsub(/ /,"",$2); print $2; exit}')"
    printf '%s|%s' "${total:-未知}" "${type:-}"
}

# 返回: "dev:size(model)[TYPE]; ..."  —— 自动区分 SSD / HDD
collect_disk() {
    local result="" first=1 name size model rota dtype
    while read -r name size model rota; do
        dtype="SSD"; [ "$rota" = "1" ] && dtype="HDD"
        [ -z "$model" ] && model="未知型号"
        [ "$first" = 1 ] || result+="; "
        result+="${name}:${size}(${model})[${dtype}]"
        first=0
    done < <(safe_cmd lsblk -d -n -o NAME,SIZE,MODEL,ROTA \
                | grep -Ev '^(loop|sr|ram|zram)')
    echo "${result:-未检测到}"
}

# 只保留已联网的物理网卡
#   输出格式: 网卡@IP@MAC，多块以分号分隔
collect_network() {
    local result="" first=1 iface ip mac
    while IFS= read -r iface; do
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*|tun*|tap*|cni*|flannel*|cali*|kube*) continue ;;
        esac

        ip="$(safe_cmd ip -4 -o addr show dev "$iface" \
                | awk '{print $4}' | paste -sd ',' -)"
        [ -z "$ip" ] && continue

        mac="$(safe_cmd ip link show "$iface" | awk '/link\/ether/ {print $2; exit}')"

        [ "$first" = 1 ] || result+="; "
        result+="${iface}@${ip}@${mac:-无}"
        first=0
    done < <(safe_cmd ip -o link show | awk -F': ' '$2 != "lo" {print $2}')
    echo "${result:-未检测到}"
}

# ============================================================================
# 三、昇腾专用（ascend_*）
# ============================================================================

# ---------------------------------------------------------------------------
# ascend_dmi_field <字段名>
#   从 ascend-dmi -i -dt 输出按字段名精确取值（同名多次出现则逐行返回）。
# ---------------------------------------------------------------------------
ascend_dmi_field() {
    local key="$1"
    has_cmd ascend-dmi || return 0
    safe_cmd ascend-dmi -i -dt | awk -v k="$key" -F: '
        {
            lhs = $1
            gsub(/^[ \t]+|[ \t]+$/, "", lhs)
            if (lhs == k) {
                rhs = $2
                gsub(/^[ \t]+|[ \t]+$/, "", rhs)
                print rhs
            }
        }'
}

# 昇腾卡是否在位：PCI Vendor 19e5 + Device dXXX
ascend_detect() {
    safe_cmd lspci -n -D | grep -qE '19e5:d[0-9a-f]{3}'
}

# 板卡型号，例如 Atlas 300I A2
ascend_npu_board() {
    ascend_dmi_field "Type" | sort -u | paste -sd'/' -
}

# 芯片型号，例如 Ascend 910B4-1
ascend_npu_chip() {
    local v
    v="$(ascend_dmi_field "Chip Name" | sort -u | paste -sd'/' -)"
    if [ -z "$v" ] && has_cmd npu-smi; then
        v="$(safe_cmd npu-smi info \
            | awk -F'|' '/^\| *[0-9]+ +[0-9A-Za-z]/ {
                n = split($2, p, /[ \t]+/); print p[n]
            }' | sort -u | paste -sd'/' -)"
    fi
    echo "$v"
}

# 单卡显存（MB，取最大值）
ascend_npu_memory() {
    local v
    v="$(ascend_dmi_field "Total (MB)" | sort -un | tail -1)"
    if [ -z "$v" ] && has_cmd npu-smi; then
        v="$(safe_cmd npu-smi info \
            | grep -oE '[0-9]+ */ *[0-9]+' \
            | awk -F'/' '{gsub(/ /,"",$2); print $2}' \
            | sort -un | tail -1)"
    fi
    echo "$v"
}

# NPU 数量
ascend_npu_count() {
    local v
    v="$(ascend_dmi_field "Card Quantity" | head -1)"
    if [ -z "$v" ] && has_cmd npu-smi; then
        v="$(safe_cmd npu-smi info \
            | awk -F'|' '/^\| *[0-9]+ +[0-9A-Za-z]/ {n++} END {print n+0}')"
    fi
    [ -z "$v" ] && v="$(safe_cmd lspci -n -D | grep -cE '19e5:d[0-9a-f]{3}')"
    echo "$v"
}

# 驱动版本号
ascend_driver_version() {
    local v
    if has_cmd npu-smi; then
        v="$(safe_cmd npu-smi info | head -5 \
            | grep -oE 'Version: *[0-9][0-9.]*' | head -1 \
            | awk '{print $2}')"
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    local f=/usr/local/Ascend/driver/version.info
    if [ -r "$f" ]; then
        grep -iE '^Version' "$f" | head -1 | awk -F= '{gsub(/ /,"",$2); print $2}'
    fi
}

# CANN 版本号
#   取值优先级：
#     1) $ASCEND_TOOLKIT_HOME 下的 version.cfg / ascend_toolkit_install.info
#     2) /usr/local/Ascend/ascend-toolkit/latest/...
#     3) /usr/local/Ascend/cann/<arch>-linux/ascend_toolkit_install.info
#     4) find 兜底搜索 ascend_toolkit_install.info
#     5) pip3 show ascend-toolkit
ascend_cann_version() {
    local v="" base f arch_dir

    # 1) 优先看环境变量 ASCEND_TOOLKIT_HOME
    if [ -n "${ASCEND_TOOLKIT_HOME:-}" ]; then
        for f in \
            "$ASCEND_TOOLKIT_HOME/version.cfg" \
            "$ASCEND_TOOLKIT_HOME/ascend_toolkit_install.info" \
            "$ASCEND_TOOLKIT_HOME/aarch64-linux/ascend_toolkit_install.info" \
            "$ASCEND_TOOLKIT_HOME/x86_64-linux/ascend_toolkit_install.info"; do
            if [ -r "$f" ]; then
                v="$(grep -iE '^version=' "$f" | head -1 \
                    | awk -F= '{gsub(/ /,"",$2); print $2}')"
                [ -n "$v" ] && { echo "$v"; return; }
            fi
        done
    fi

    # 2) 常见安装路径
    for base in /usr/local/Ascend /usr/local/Ascend/ascend-toolkit; do
        for f in \
            "$base/ascend-toolkit/latest/version.cfg" \
            "$base/ascend-toolkit/latest/ascend_toolkit_install.info" \
            "$base/latest/version.cfg" \
            "$base/latest/ascend_toolkit_install.info"; do
            if [ -r "$f" ]; then
                v="$(grep -iE '^version=' "$f" | head -1 \
                    | awk -F= '{gsub(/ /,"",$2); print $2}')"
                [ -n "$v" ] && { echo "$v"; return; }
            fi
        done
    done

    # 3) /usr/local/Ascend/cann/<arch>-linux/ 安装信息
    for arch_dir in aarch64-linux x86_64-linux; do
        f="/usr/local/Ascend/cann/$arch_dir/ascend_toolkit_install.info"
        if [ -r "$f" ]; then
            v="$(grep -iE '^version=' "$f" | head -1 \
                | awk -F= '{gsub(/ /,"",$2); print $2}')"
            [ -n "$v" ] && { echo "$v"; return; }
        fi
    done

    # 4) find 兜底
    if has_cmd find; then
        f="$(find /usr/local/Ascend -maxdepth 5 -name 'ascend_toolkit_install.info' 2>/dev/null | head -1)"
        if [ -n "$f" ] && [ -r "$f" ]; then
            v="$(grep -iE '^version=' "$f" | head -1 \
                | awk -F= '{gsub(/ /,"",$2); print $2}')"
            [ -n "$v" ] && { echo "$v"; return; }
        fi
    fi

    # 5) pip3 兜底
    if has_cmd pip3; then
        v="$(pip3 show ascend-toolkit 2>/dev/null \
            | awk -F: '/^Version/ {gsub(/ /,"",$2); print $2}')"
    fi
    echo "$v"
}

# ---------------------------------------------------------------------------
# ascend_device_map - 映射NPU序号（按板卡型号分组，防混插）
#   取 ascend-dmi 的 Card ID（与 npu-smi 的 NPU 编号一致），
#   而非 Device ID（驱动内部索引，通常从 0 开始，会错位）。
#   输出格式: 板卡型号@CardID列表，多组以分号分隔
# ---------------------------------------------------------------------------
ascend_device_map() {
    local v=""
    if has_cmd ascend-dmi; then
        v="$(safe_cmd ascend-dmi -i -dt \
            | awk -F: '
                {
                    lhs = $1
                    gsub(/^[ \t]+|[ \t]+$/, "", lhs)
                    rhs = $2
                    gsub(/^[ \t]+|[ \t]+$/, "", rhs)
                    if (lhs == "Type") cur_type = rhs
                    else if (lhs == "Card ID" && cur_type != "") {
                        print cur_type "@" rhs
                    }
                }' \
            | awk -F'@' '
                {
                    t = $1; d = $2
                    if (!(t in ids)) { order[++n] = t; ids[t] = d }
                    else { ids[t] = ids[t] "," d }
                }
                END {
                    for (i = 1; i <= n; i++) {
                        if (i > 1) printf "; "
                        m = split(ids[order[i]], arr, ",")
                        for (a = 1; a <= m; a++)
                            for (b = a+1; b <= m; b++)
                                if (arr[a]+0 > arr[b]+0) {
                                    tmp=arr[a]; arr[a]=arr[b]; arr[b]=tmp
                                }
                        printf "%s@", order[i]
                        for (a = 1; a <= m; a++)
                            printf "%s%s", (a>1?",":""), arr[a]
                    }
                }')"
    fi

    # 回退：npu-smi 的 NPU 编号本身就是 Card ID，无需转换
    if [ -z "$v" ] && has_cmd npu-smi; then
        v="$(safe_cmd npu-smi info \
            | awk -F'|' '/^\| *[0-9]+ +[0-9A-Za-z]/ {
                gsub(/^[ \t]+|[ \t]+$/, "", $2)
                split($2, p, /[ \t]+/)
                if (!(p[1] in s)) { s[p[1]]=1; list = list (list?",":"") p[1] }
            } END { print list }')"
    fi
    echo "$v"
}

# ---------------------------------------------------------------------------
# ascend_report - 输出昇腾相关 CSV 行
# ---------------------------------------------------------------------------
ascend_report() {
    local chip mem board count driver cann devmap model_str=""

    board="$(ascend_npu_board)"
    chip="$(ascend_npu_chip)"
    mem="$(ascend_npu_memory)"
    count="$(ascend_npu_count)"
    driver="$(ascend_driver_version)"
    cann="$(ascend_cann_version)"
    devmap="$(ascend_device_map)"

    [ -n "$board" ] && model_str+="$board"
    [ -n "$chip" ]  && model_str+="${model_str:+@}$chip"
    [ -n "$mem" ]   && model_str+="${model_str:+@}${mem}MB"
    [ -n "$count" ] && model_str+="${model_str:+@}$count"
    [ -z "$model_str" ] && model_str="未知"

    csv_row "NPU型号"     "$model_str"     "板卡@芯片@单卡显存@数量"
    csv_row "驱动版本号"  "${driver:-未知}" "—"
    csv_row "CANN版本号"  "${cann:-未知}"   "—"
    csv_row "映射NPU序号" "${devmap:-未知}" "板卡型号@CardID"
}

# ---------------------------------------------------------------------------
# collect_accelerator - 加速卡汇总入口
# ---------------------------------------------------------------------------
collect_accelerator() {
    if ascend_detect; then
        ascend_report
    else
        csv_row "NPU型号" "未检测到" "PCI 未发现昇腾卡"
    fi
}

# ============================================================================
# 四、主流程
# ============================================================================
main() {
    # 输出 UTF-8 BOM，让 Windows Excel 正确识别中文
    printf '\xEF\xBB\xBF'
    csv_row "项目" "配置" "说明"

    # 操作系统
    csv_row "操作系统" "$(collect_os)" "—"

    # 内核
    csv_row "内核" "$(collect_kernel)" "—"

    # CPU
    #   配置列: 型号@每座核数Core/每座线程数Thread@座数Socket
    #   例    : Kunpeng-920@64Core/64Thread@2Socket
    #   说明列: 架构 aarch64；共 <核数>Core/<线程数>Thread（所有座合计）
    local cpu_model cpu_cores cpu_threads cpu_arch cpu_sockets
    IFS='|' read -r cpu_model cpu_cores cpu_threads cpu_arch cpu_sockets <<< "$(collect_cpu)"

    local total_cores total_threads cpu_note
    if [[ "$cpu_cores" =~ ^[0-9]+$ ]] && [[ "$cpu_sockets" =~ ^[0-9]+$ ]]; then
        total_cores=$(( cpu_cores * cpu_sockets ))
    else
        total_cores="未知"
    fi
    if [[ "$cpu_threads" =~ ^[0-9]+$ ]] && [[ "$cpu_sockets" =~ ^[0-9]+$ ]]; then
        total_threads=$(( cpu_threads * cpu_sockets ))
    else
        total_threads="未知"
    fi

    cpu_note="架构 $cpu_arch；共 ${total_cores}Core/${total_threads}Thread"

    csv_row "CPU型号" \
        "${cpu_model}@${cpu_cores}Core/${cpu_threads}Thread@${cpu_sockets}Socket" \
        "$cpu_note"

    # 内存 —— 格式: 250Gi@DDR4
    local mem_total mem_type mem_cfg
    IFS='|' read -r mem_total mem_type <<< "$(collect_memory)"
    mem_cfg="$mem_total"
    [ -n "$mem_type" ] && mem_cfg+="@$mem_type"
    csv_row "内存" "$mem_cfg" "—"

    # 存储 —— 格式: 设备:容量(型号)[类型]，多块以分号分隔
    csv_row "存储" "$(collect_disk)" "设备:容量(型号)[类型]"

    # 网络 —— 格式: 网卡@IP@MAC
    csv_row "IP-MAC" "$(collect_network)" "网卡@IP@MAC"

    # 加速卡
    collect_accelerator

    # Docker 镜像 —— 暂时无法采集，留空
    csv_row "Docker镜像" "未知" "—"

    # 采集日期
    csv_row "获取日期" "$(date '+%Y-%m-%d %H:%M:%S')" "—"
}

main "$@"