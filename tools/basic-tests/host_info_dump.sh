#!/bin/bash
###############################################################################
# host_info_dump.sh - Host information summary script
#
# Purpose:
#   Collect OS / kernel / CPU / memory / storage / network / accelerator (NPU)
#   information and emit it as CSV with three columns: "Item,Config,Note".
#
# Naming convention:
#   Generic collection : collect_*
#   Accelerator        : <vendor>_*   -- Ascend: ascend_*; future extensions:
#                        nv_* (NVIDIA), dcu_* (Hygon DCU), etc.
#
# Accelerator data source priority:
#   1) ascend-dmi -i -dt   (official diagnostic tool, structured fields, preferred)
#   2) npu-smi info        (secondary)
#   3) lspci / version.info(fallback)
#
# Usage:
#   bash host_info_dump.sh                      # print to terminal
#   bash host_info_dump.sh > info-host.csv      # save as CSV
###############################################################################

set -o pipefail
export LC_ALL=C

# ============================================================================
# I. Generic utilities
# ============================================================================
csv_field() { local v="${1:-}"; v="${v//\"/\"\"}"; printf '"%s"' "$v"; }
csv_row()   { printf '%s,%s,%s\n' "$(csv_field "$1")" "$(csv_field "$2")" "$(csv_field "$3")"; }
safe_cmd()  { "$@" 2>/dev/null || true; }
has_cmd()   { command -v "$1" >/dev/null 2>&1; }

# ============================================================================
# II. Generic collection
# ============================================================================

# OS name (without kernel version)
collect_os() {
    local pretty=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        pretty="${PRETTY_NAME:-${NAME:-unknown} ${VERSION:-}}"
    fi
    printf '%s' "${pretty:-unknown}"
}

# Kernel version
collect_kernel() {
    safe_cmd uname -r
}

# Returns: model|cps|cps_threads|arch|sockets
#   cps         = cores per socket
#   cps_threads = threads per socket = cps x Thread(s) per core
#   sockets     = number of CPU sockets
collect_cpu() {
    local model arch sockets cps tpc cps_threads total

    model="$(safe_cmd lscpu | awk -F: '/^Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
    [ -z "$model" ] && model="$(safe_cmd lscpu | awk -F: '/^BIOS Model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"
    [ -z "$model" ] && model="$(safe_cmd lscpu | awk -F: '/^Hardware/ {sub(/^[ \t]+/,"",$2); print $2; exit}')"

    arch="$(safe_cmd uname -m)"
    sockets="$(safe_cmd lscpu | awk -F: '/^Socket\(s\)/ {gsub(/ /,"",$2); print $2}')"
    cps="$(safe_cmd lscpu | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}')"
    tpc="$(safe_cmd lscpu | awk -F: '/^Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}')"

    # Fall back to 1 socket if parsing failed
    [[ "$sockets" =~ ^[0-9]+$ ]] || sockets=1
    # Fall back to 1 thread per core if parsing failed
    [[ "$tpc" =~ ^[0-9]+$ ]] || tpc=1

    # If cps parsing failed, fall back to nproc / sockets
    if ! [[ "$cps" =~ ^[0-9]+$ ]]; then
        total="$(safe_cmd nproc)"
        if [[ "$total" =~ ^[0-9]+$ ]]; then
            cps=$(( total / sockets ))
        else
            cps="unknown"
        fi
    fi

    if [[ "$cps" =~ ^[0-9]+$ ]]; then
        cps_threads=$(( cps * tpc ))
    else
        cps_threads="unknown"
    fi

    printf '%s|%s|%s|%s|%s' \
        "${model:-unknown}" "$cps" "$cps_threads" "${arch:-unknown}" "$sockets"
}

# Returns: total|type
collect_memory() {
    local total type
    total="$(safe_cmd free -h | awk '/^Mem:/ {print $2}')"
    type="$(safe_cmd dmidecode -t memory \
        | awk -F: '/^[ \t]*Type:/ && $2 !~ /Unknown|Other|None/ {gsub(/ /,"",$2); print $2; exit}')"
    printf '%s|%s' "${total:-unknown}" "${type:-}"
}

# Returns: "dev:size(model)[TYPE]; ..."  -- SSD / HDD auto-detected
collect_disk() {
    local result="" first=1 name size model rota dtype
    while read -r name size model rota; do
        dtype="SSD"; [ "$rota" = "1" ] && dtype="HDD"
        [ -z "$model" ] && model="unknown-model"
        [ "$first" = 1 ] || result+="; "
        result+="${name}:${size}(${model})[${dtype}]"
        first=0
    done < <(safe_cmd lsblk -d -n -o NAME,SIZE,MODEL,ROTA \
                | grep -Ev '^(loop|sr|ram|zram)')
    echo "${result:-none detected}"
}

# Keep only connected physical NICs.
#   Filter rules (order matters):
#     1) Exclude loopback / virtual / container interfaces
#     2) operstate must be up (links that are down are skipped)
#     3) Then read carrier and confirm it is 1 (avoids the kernel reporting
#        "Invalid argument" for carrier when the link is down)
#     4) At least one IPv4 address must exist
#   Output format: iface@IP@MAC, multiple entries separated by semicolons
collect_network() {
    local result="" first=1 iface ip mac oper carrier

    while IFS= read -r iface; do
        # 1) Filter virtual/container/loopback interfaces
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*|tun*|tap*|cni*|flannel*|cali*|kube*) continue ;;
        esac

        # 2) Check operstate first to avoid carrier errors when link is down
        oper="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)"
        [ "$oper" = "up" ] || continue

        # 3) Confirm carrier=1 (physical link really up)
        carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)"
        [ "$carrier" = "1" ] || continue

        # 4) At least one IPv4 address required
        ip="$(safe_cmd ip -4 -o addr show dev "$iface" \
                | awk '{print $4}' | paste -sd ',' -)"
        [ -z "$ip" ] && continue

        mac="$(safe_cmd ip link show "$iface" | awk '/link\/ether/ {print $2; exit}')"

        [ "$first" = 1 ] || result+="; "
        result+="${iface}@${ip}@${mac:-none}"
        first=0
    done < <(safe_cmd ip -o link show | awk -F': ' '$2 != "lo" {print $2}')
    echo "${result:-none detected}"
}

# ============================================================================
# III. Ascend-specific (ascend_*)
# ============================================================================

# ---------------------------------------------------------------------------
# ascend_dmi_field <field-name>
#   Extract a value by exact field name from `ascend-dmi -i -dt` output
#   (if the same name appears multiple times, return one line per match).
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

# Is an Ascend card present: PCI Vendor 19e5 + Device dXXX
ascend_detect() {
    safe_cmd lspci -n -D | grep -qE '19e5:d[0-9a-f]{3}'
}

# Board model, e.g. Atlas 300I A2
ascend_npu_board() {
    ascend_dmi_field "Type" | sort -u | paste -sd'/' -
}

# Chip model, e.g. Ascend 910B4-1
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

# Per-card memory (MB, take the maximum)
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

# NPU count
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

# Driver version
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

# CANN version
#   Value priority:
#     1) version.cfg / ascend_toolkit_install.info under $ASCEND_TOOLKIT_HOME
#     2) version.cfg / version.info / ascend_toolkit_install.info under
#        /usr/local/Ascend/cann (including aarch64-linux / x86_64-linux /
#        arm64-linux subdirectories)
#     3) Legacy layout /usr/local/Ascend/ascend-toolkit/latest/
#     4) Directory-name fallback /usr/local/Ascend/cann-<version> (e.g. cann-9.1.1)
#     5) find fallback searching for ascend_toolkit_install.info
#     6) pip3 show ascend-toolkit
ascend_cann_version() {
    local v="" f d

    # 1) Prefer the ASCEND_TOOLKIT_HOME environment variable
    if [ -n "${ASCEND_TOOLKIT_HOME:-}" ]; then
        for f in \
            "$ASCEND_TOOLKIT_HOME/version.cfg" \
            "$ASCEND_TOOLKIT_HOME/version.info" \
            "$ASCEND_TOOLKIT_HOME/ascend_toolkit_install.info" \
            "$ASCEND_TOOLKIT_HOME/aarch64-linux/ascend_toolkit_install.info" \
            "$ASCEND_TOOLKIT_HOME/x86_64-linux/ascend_toolkit_install.info" \
            "$ASCEND_TOOLKIT_HOME/arm64-linux/ascend_toolkit_install.info"; do
            if [ -r "$f" ]; then
                v="$(grep -iE '^version *=' "$f" | head -1 \
                    | awk -F= '{gsub(/ /,"",$2); print $2}')"
                [ -n "$v" ] && { echo "$v"; return; }
            fi
        done
    fi

    # 2) CANN 9.x new layout: /usr/local/Ascend/cann/...
    for f in \
        /usr/local/Ascend/cann/version.cfg \
        /usr/local/Ascend/cann/version.info \
        /usr/local/Ascend/cann/ascend_toolkit_install.info \
        /usr/local/Ascend/cann/aarch64-linux/ascend_toolkit_install.info \
        /usr/local/Ascend/cann/x86_64-linux/ascend_toolkit_install.info \
        /usr/local/Ascend/cann/arm64-linux/ascend_toolkit_install.info; do
        if [ -r "$f" ]; then
            v="$(grep -iE '^version *=' "$f" | head -1 \
                | awk -F= '{gsub(/ /,"",$2); print $2}')"
            [ -n "$v" ] && { echo "$v"; return; }
        fi
    done

    # 3) Legacy layout: /usr/local/Ascend/ascend-toolkit/latest/...
    for f in \
        /usr/local/Ascend/ascend-toolkit/latest/version.cfg \
        /usr/local/Ascend/ascend-toolkit/latest/ascend_toolkit_install.info; do
        if [ -r "$f" ]; then
            v="$(grep -iE '^version *=' "$f" | head -1 \
                | awk -F= '{gsub(/ /,"",$2); print $2}')"
            [ -n "$v" ] && { echo "$v"; return; }
        fi
    done

    # 4) Directory-name fallback: /usr/local/Ascend/cann-<version>
    for d in /usr/local/Ascend/cann-*/; do
        [ -d "$d" ] || continue
        v="$(basename "$d" | sed -n 's/^cann-//p')"
        [ -n "$v" ] && { echo "$v"; return; }
    done

    # 5) find fallback
    if has_cmd find; then
        f="$(find /usr/local/Ascend -maxdepth 5 -name 'ascend_toolkit_install.info' 2>/dev/null | head -1)"
        if [ -n "$f" ] && [ -r "$f" ]; then
            v="$(grep -iE '^version *=' "$f" | head -1 \
                | awk -F= '{gsub(/ /,"",$2); print $2}')"
            [ -n "$v" ] && { echo "$v"; return; }
        fi
    fi

    # 6) pip3 fallback
    if has_cmd pip3; then
        v="$(pip3 show ascend-toolkit 2>/dev/null \
            | awk -F: '/^Version/ {gsub(/ /,"",$2); print $2}')"
    fi
    echo "$v"
}

# ---------------------------------------------------------------------------
# ascend_device_map - map NPU indices (grouped by board model, guard against
#                     mixed installations).
#   Use ascend-dmi's Card ID (consistent with npu-smi's NPU numbering),
#   NOT the Device ID (driver-internal index, usually starting from 0, which
#   would be misaligned).
#   Output format: board-model@CardID-list, groups separated by semicolons
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

    # Fallback: npu-smi's NPU number is already the Card ID, no conversion needed
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
# ascend_report - emit Ascend-related CSV rows
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
    [ -z "$model_str" ] && model_str="unknown"

    csv_row "NPU Model"       "$model_str"     "board@chip@mem-per-card@count"
    csv_row "Driver Version"  "${driver:-unknown}" "—"
    csv_row "CANN Version"    "${cann:-unknown}"   "—"
    csv_row "NPU ID Mapping"  "${devmap:-unknown}" "board-model@CardID"
}

# ---------------------------------------------------------------------------
# collect_accelerator - accelerator summary entry point
# ---------------------------------------------------------------------------
collect_accelerator() {
    if ascend_detect; then
        ascend_report
    else
        csv_row "NPU Model" "none detected" "no Ascend card found on PCI"
    fi
}

# ============================================================================
# IV. Main flow
# ============================================================================

# CPU row: model, per-socket config, and total core/thread note
emit_cpu() {
    local cpu_model cpu_cores cpu_threads cpu_arch cpu_sockets
    local total_cores total_threads cpu_note

    IFS='|' read -r cpu_model cpu_cores cpu_threads cpu_arch cpu_sockets <<< "$(collect_cpu)"

    if [[ "$cpu_cores" =~ ^[0-9]+$ ]] && [[ "$cpu_sockets" =~ ^[0-9]+$ ]]; then
        total_cores=$(( cpu_cores * cpu_sockets ))
    else
        total_cores="unknown"
    fi
    if [[ "$cpu_threads" =~ ^[0-9]+$ ]] && [[ "$cpu_sockets" =~ ^[0-9]+$ ]]; then
        total_threads=$(( cpu_threads * cpu_sockets ))
    else
        total_threads="unknown"
    fi

    cpu_note="arch $cpu_arch; total ${total_cores}Core/${total_threads}Thread"

    csv_row "CPU Model" \
        "${cpu_model}@${cpu_cores}Core/${cpu_threads}Thread@${cpu_sockets}Socket" \
        "$cpu_note"
}

# Memory row: total@type
emit_memory() {
    local mem_total mem_type mem_cfg
    IFS='|' read -r mem_total mem_type <<< "$(collect_memory)"
    mem_cfg="$mem_total"
    [ -n "$mem_type" ] && mem_cfg+="@$mem_type"
    csv_row "Memory" "$mem_cfg" "—"
}

main() {
    # Emit a UTF-8 BOM so Windows Excel recognizes the encoding correctly
    printf '\xEF\xBB\xBF'
    csv_row "Item" "Config" "Note"

    # OS
    csv_row "OS" "$(collect_os)" "—"

    # Kernel
    csv_row "Kernel" "$(collect_kernel)" "—"

    # CPU
    #   Config column: model@cores-per-socketCore/threads-per-socketThread@socketCountSocket
    #   e.g.: Kunpeng-920@64Core/64Thread@2Socket
    #   Note column : arch aarch64; total <cores>Core/<threads>Thread (all sockets)
    emit_cpu

    # Memory -- format: 250Gi@DDR4
    emit_memory

    # Storage -- format: device:capacity(model)[type], multiple entries separated by semicolons
    csv_row "Storage" "$(collect_disk)" "device:capacity(model)[type]"

    # Network -- format: iface@IP@MAC (only physical NICs with link up)
    csv_row "IP-MAC" "$(collect_network)" "iface@IP@MAC"

    # Accelerator
    collect_accelerator

    # Docker images -- not collectable yet, left blank
    csv_row "Docker Image" "unknown" "—"

    # Collection date
    csv_row "Collect Date" "$(date '+%Y-%m-%d %H:%M:%S')" "—"
}

main "$@"
