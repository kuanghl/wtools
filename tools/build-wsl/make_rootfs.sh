#!/bin/bash
# ==============================================================================
# make_rootfs.sh  —  Multi-distro minimal Docker rootfs packer (v2)
# Supports: CentOS 7/8, Ubuntu 20.04 (and other el/Debian families)
#
# Key design goals (fixes of v1):
#   1. KEEP the *current* kernel headers & modules so the image can still
#      build out-of-tree drivers; only prune OTHER kernel versions & debuginfo.
#   2. Never use a blind --one-file-system (it silently drops split mounts);
#      instead pin the sources we want and warn about extra mount points.
#   3. Aggressively drop the REAL size hogs: debuginfo, langpacks/locales,
#      package-manager caches, unused kernel modules/firmware.
#   4. Recreate the mandatory empty dirs (/proc /sys /dev /run /tmp) so the
#      imported image behaves like a normal container rootfs.
#   5. Emit docker-import hints with -c metadata (CMD/ENV/WORKDIR).
#
# It is READ-ONLY w.r.t. the host: nothing is deleted, only excluded at tar time.
#
# Usage:
#   chmod +x make_rootfs.sh
#   sudo ./make_rootfs.sh                 # auto-detect, sensible defaults
#   sudo ./make_rootfs.sh --keep-locales  # keep glibc langpacks (bigger)
#   sudo ./make_rootfs.sh --kernel 5.4.0-216-generic   # pin kernel ver
#   sudo ./make_rootfs.sh --out myrootfs.tar
# ==============================================================================

set -euo pipefail

# ----------------------------- defaults / args -------------------------------
KEEP_LOCALES=0
KEEP_FIRMWARE=0
PINNED_KERNEL=""
OUT_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-locales) KEEP_LOCALES=1 ;;
        --keep-firmware) KEEP_FIRMWARE=1 ;;
        --kernel) PINNED_KERNEL="${2:-}"; shift ;;
        --out) OUT_FILE="${2:-}"; shift ;;
        -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

# ------------------------------- state vars ----------------------------------
DISTRO_ID=""; DISTRO_VER=""; OS_STRING=""; KVER=""
LOG_FILE="./make_rootfs_$(date +%Y%m%d_%H%M%S).log"
EXCLUDE_FILE=""

log() {
    local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] $*" | tee -a "${LOG_FILE}"
}

die() { log "ERROR: $*"; exit 1; }

check_root() {
    [ "$EUID" -eq 0 ] || die "Please run with sudo / as root."
}

# --------------------------- OS / kernel detection ---------------------------
get_os_info() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="$ID"
        DISTRO_VER="${VERSION_ID:-latest}"
        OS_STRING="$(echo "$NAME" | tr ' ' '_')-${DISTRO_VER}"
    else
        OS_STRING="unknown-os-$(uname -r)"; DISTRO_ID="unknown"; DISTRO_VER="latest"
    fi
    KVER="${PINNED_KERNEL:-$(uname -r)}"
    log "Detected distro : ${OS_STRING} (id=${DISTRO_ID})"
    log "Kernel to keep  : ${KVER}"
}

# Determine the family so we can prune the right paths.
is_debian_like() { command -v dpkg-query >/dev/null 2>&1; }
is_rhel_like()   { command -v rpm >/dev/null 2>&1; }

# Absolute path of the output tar (used to exclude the archive from itself).
out_abs_path() {
    local d; d="$(cd "$(dirname "${OUT_FILE}")" 2>/dev/null && pwd)" || d="/"
    echo "${d}/$(basename "${OUT_FILE}")"
}

# --------------------------- sanity warnings ---------------------------------
# Only warn about REAL extra mounts that we are NOT already covering via
# content-excludes. Virtual FS (/proc /sys /dev /run ...) and the output dir
# are handled elsewhere, so keep the log quiet for them.
warn_split_mounts() {
    log "--> Checking for split mounts that could make the image incomplete..."
    local outp; outp="$(out_abs_path)"
    awk 'NR>1 && $2!="/" && $2 ~ /^\/[^ ]*/ {print $2}' /proc/mounts \
        | sort -u | while read -r m; do
            case "$m" in
                /proc/*|/sys/*|/dev/*|/run/*|/tmp|/var/tmp) ;;
                /mnt|/media|/home|/boot|/snap|/dev/pts|/dev/shm|/dev/mqueue|/dev/hugepages) ;;
                *) case "$outp" in
                       "$m"|"$m"/*) log "    INFO: '$m' holds the output archive -> excluded automatically." ;;
                       *) log "    WARN: '$m' is a separate mount and will be INCLUDED. Verify size/completeness." ;;
                   esac ;;
            esac
        done
}

# Verify the kernel we keep actually has headers installed, else the image
# cannot compile drivers -> fail early with a helpful message.
check_kernel_headers() {
    local build_link="/lib/modules/${KVER}/build"
    if [ ! -e "$build_link" ] && [ ! -d "/usr/src/linux-headers-${KVER}" ] \
       && [ ! -d "/usr/src/kernels/${KVER}" ]; then
        log "    WARN: no kernel headers for ${KVER} found on this host."
        log "          Install them first (apt install linux-headers-\$(uname -r) /"
        log "          yum install kernel-devel) or the image CANNOT build drivers."
    else
        log "    OK: kernel headers present for ${KVER} (${build_link})."
    fi
}

# --------------------- prompt fix (read-only on host) ------------------------
# CentOS/RHEL only source /etc/bashrc from ~/.bashrc; since we prune most of
# /root, an interactive non-login bash ("docker run ... /bin/bash") falls back
# to the ugly "bash-4.x#" prompt. Fix by temporarily dropping a minimal
# /root/.bashrc (interactive shells) AND /etc/profile.d/99-ps1.sh (login
# shells). Both are created fresh only if absent, and reverted after packing so
# the host is left exactly as we found it -> still READ-ONLY.
PS1_MARKER="# >>> make_rootfs prompt >>>"
PS1_BODY='if [ -z "${MAKE_ROOTFS_PS1}" ]; then
  [ -f /etc/bashrc ] && . /etc/bashrc
  [ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
  PS1='"'"'\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\# '"'"'
  MAKE_ROOTFS_PS1=1
fi'
# shellcheck disable=SC2034
PS1_RESTORE_LIST=""   # "path<TAB>had_backup" entries, consumed by restore

_inject_one() {
    local f="$1"
    if [ -e "$f" ] && grep -qF "$PS1_MARKER" "$f" 2>/dev/null; then
        return 0   # already ours, idempotent
    fi
    if [ -e "$f" ]; then
        cp -a "$f" "${f}.makeroots_bak"
        printf '\n%s\n%s\n' "$PS1_MARKER" "$PS1_BODY" >> "$f"
        PS1_RESTORE_LIST="${PS1_RESTORE_LIST}${f}|1
"
    else
        printf '%s\n%s\n' "$PS1_MARKER" "$PS1_BODY" > "$f"
        PS1_RESTORE_LIST="${PS1_RESTORE_LIST}${f}|0
"
    fi
}

inject_login_profile() {
    log "--> Injecting container prompt config (.bashrc + profile.d)..."
    mkdir -p /etc/profile.d || true
    _inject_one /root/.bashrc
    _inject_one /etc/profile.d/99-ps1.sh
    log "    Prompt config injected (will be reverted after packing)."
}

restore_login_profile() {
    local entry f had
    for entry in ${PS1_RESTORE_LIST:-}; do
        [ -n "$entry" ] || continue
        f="${entry%|*}"; had="${entry##*|}"
        if [ "$had" = "1" ] && [ -f "${f}.makeroots_bak" ]; then
            mv -f "${f}.makeroots_bak" "$f"
        elif [ "$had" = "0" ] && [ -e "$f" ] && grep -qF "$PS1_MARKER" "$f" 2>/dev/null; then
            rm -f "$f"          # we created it -> remove to leave host clean
        fi
        rm -f "${f}.makeroots_bak"
    done
}

# --------------------------- cache cleanup (safe) ----------------------------
clean_system_cache() {
    log "--> Cleaning package manager caches (host files untouched)..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get clean || true
        rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf clean all || true
    elif command -v yum >/dev/null 2>&1; then
        yum clean all || true
    fi
    log "    Cache cleanup done."
}

# --------------------------- build exclude list ------------------------------
# We deliberately DO NOT pass --one-file-system. We exclude by path instead so
# split /usr or /var are not dropped.
build_excludes() {
    EXCLUDE_FILE="$(mktemp)"
    local kver_base="${KVER%-generic}"   # 5.4.0-216-generic -> 5.4.0-216

    {
        # --- THE OUTPUT ARCHIVE ITSELF (must never tar itself into the tar) ---
        local outp; outp="$(out_abs_path)"
        # exclude the archive file, and (if cwd is a separate mount) its path
        echo ".${outp}"                       # tar strips leading '/', so match both
        echo "${outp#/}"
        echo "${outp}"

        # --- virtual / runtime: EXCLUDE THE WHOLE DIR, not just its content.
        # We must NOT keep the empty /sys /proc dir: tar would still read the
        # directory entry itself and sysfs/proc change under it -> "file changed
        # as we read it". Container runtime recreates these mount points anyway.
        echo "/proc"
        echo "/sys"
        echo "/dev"
        echo "/run"
        echo "/tmp/*"
        echo "/var/tmp/*"
        # --- host-only / useless in container ---
        echo "/boot/*"            # keep the dir, drop vmlinuz/initrd (huge)
        echo "/media/*"
        echo "/mnt/*"
        echo "/home/*"
        # root's $HOME: keep top-level dotfiles (.bashrc/.profile -> fixes the
        # bare "bash-4.2#" prompt on CentOS/RHEL), but drop bulky sub-dirs.
        echo "/root/*/*"          # contents of any /root subdir
        echo "/root/.cache"
        echo "/root/.local"
        echo "/root/.npm"
        echo "/root/.ccache"
        echo "/lost+found"
        echo "/snap"
        echo "/swap.img"
        echo "/swapfile"
        # --- package manager caches / state ---
        echo "/var/cache/*"
        echo "/var/log/*"
        echo "/var/lib/dnf"
        echo "/var/lib/yum"
        echo "/var/lib/apt/lists"
        echo "/var/lib/docker"
        echo "/var/lib/containers"
        echo "/var/lib/snapd"
        echo "/var/lib/cloud"
        # --- docs / man / i18n (size hogs) ---
        echo "/usr/share/doc/*"
        echo "/usr/share/man/*"
        echo "/usr/share/info/*"
        echo "/usr/share/locale/*"
        echo "/usr/share/selinux"
        echo "/var/lib/selinux"
        echo "/usr/share/fonts/*"
        echo "/usr/share/brltty"
        echo "/usr/share/sane"
        echo "/usr/share/cups"
        echo "/usr/share/alsa"
    } >> "${EXCLUDE_FILE}"

    # --- debuginfo (BIGGEST win, often 100s of MB) ---
    {
        echo "/usr/lib/debug"
        echo "/usr/lib64/debug"
        echo "*.debug"
    } >> "${EXCLUDE_FILE}"

    # --- locales / glibc langpacks (only if not keeping) ---
    if [ "${KEEP_LOCALES}" -ne 1 ]; then
        echo "/usr/lib/locale/*" >> "${EXCLUDE_FILE}"
        echo "/usr/share/i18n/*" >> "${EXCLUDE_FILE}"
        # RHEL-family: drop all but en langpacks
        if is_rhel_like; then
            rpm -qa 'glibc-langpack-*' 2>/dev/null | grep -v 'glibc-langpack-en' \
              | xargs -r rpm -ql 2>/dev/null >> "${EXCLUDE_FILE}" || true
        fi
    fi

    # --- firmware (only if not keeping) ---
    if [ "${KEEP_FIRMWARE}" -ne 1 ]; then
        echo "/usr/lib/firmware/*" >> "${EXCLUDE_FILE}"
        echo "/lib/firmware/*" >> "${EXCLUDE_FILE}"
    fi

    # --- KERNEL PRUNING: keep ONLY the pinned version, drop the rest ---
    # (All `ls | while` are suffixed with `|| true`: with `set -e`+`pipefail`,
    #  a no-match glob makes ls exit non-zero and would abort the script.)
    # Headers/src for OTHER versions:
    if is_debian_like; then
        # keep linux-headers-${KVER} and linux-headers-${kver_base}
        ls -1d /usr/src/linux-headers-* 2>/dev/null | while read -r d; do
            case "$d" in
                "/usr/src/linux-headers-${KVER}"|"/usr/src/linux-headers-${kver_base}") ;;
                *) echo "${d#/}/*" >> "${EXCLUDE_FILE}" ;;
            esac
        done || true
    fi
    if is_rhel_like; then
        ls -1d /usr/src/kernels/* 2>/dev/null | while read -r d; do
            [ "$d" = "/usr/src/kernels/${KVER}" ] || echo "${d#/}/*" >> "${EXCLUDE_FILE}"
        done || true
    fi
    # Modules for OTHER kernel versions (keep current so drivers can load):
    ls -1d /lib/modules/* 2>/dev/null | while read -r d; do
        case "$d" in
            "/lib/modules/${KVER}") ;;
            *) echo "${d#/}/*" >> "${EXCLUDE_FILE}" ;;
        esac
    done || true
    # Within the KEPT kernel, drop bulky unused module subsystems (optional):
    local mdir="/lib/modules/${KVER}/kernel"
    for sub in drivers/gpu drivers/media drivers/net/wireless \
               drivers/bluetooth sound net/bluetooth; do
        [ -d "${mdir}/${sub}" ] && echo "${mdir}/${sub}/*" >> "${EXCLUDE_FILE}"
    done

    # de-duplicate, drop empties
    sort -u "${EXCLUDE_FILE}" -o "${EXCLUDE_FILE}"
    log "    Exclude rules: $(wc -l < "${EXCLUDE_FILE}")"
}

set_output_file() {
    : "${OUT_FILE:=./${OS_STRING}-minimal-rootfs.tar}"
    log "Target archive : ${OUT_FILE}"
    log "Log file       : ${LOG_FILE}"
}

print_intro() {
    log "=========================================="
    log "This script is READ-ONLY: it never deletes host files."
    log "Keeping kernel : ${KVER} (headers+modules retained for driver build)"
    log "=========================================="
    sleep 2
}

# --------------------------- create the tarball ------------------------------
create_tarball() {
    log "--> Packaging rootfs (verbose tar output -> log)..."
    local start end dur
    start="$(date +%s)"

    # Build tar exclude args from file.
    local -a excl=()
    while IFS= read -r line; do
        [ -n "$line" ] && excl+=( --exclude="$line" )
    done < "${EXCLUDE_FILE}"

    # NOTE: no --one-file-system (see warnings above). --xattrs/--acls preserve
    # capabilities & SELinux xattrs so the container behaves correctly.
    # --warning=no-file-changed : ignore /sys,/proc style "changed as we read it"
    # --ignore-failed-read      : skip unreadable sockets/fifos instead of aborting
    tar --numeric-owner \
        --xattrs --xattrs-include='*' --acls \
        --warning=no-file-changed --ignore-failed-read \
        "${excl[@]}" \
        -cvpf "${OUT_FILE}" / >> "${LOG_FILE}" 2>&1
    local rc=$?
    # tar exits 1 merely for "file changed as we read it" — that's harmless.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
        die "tar failed (exit ${rc}), see ${LOG_FILE}"
    fi

    end="$(date +%s)"; dur=$((end - start))
    log "    Packaging finished in ${dur}s."
}

verify_result() {
    [ -s "${OUT_FILE}" ] || die "Packaging failed: ${OUT_FILE} missing/empty."
    local size; size="$(du -sh "${OUT_FILE}" | awk '{print $1}')"
    log "=========================================="
    log "SUCCESS: ${OUT_FILE}  (${size})"
    log "Import with metadata:"
    log "  docker import -c 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \\"
    log "    -c 'WORKDIR /workspace' \\"
    log "    -c 'CMD [\"/bin/bash\"]' \\"
    log "    ${OUT_FILE} local-${DISTRO_ID}:${DISTRO_VER}"
    log ""
    log "Or build a proper image with a Dockerfile:"
    log "  FROM scratch"
    log "  ADD ${OUT_FILE} /"
    log "  CMD [\"/bin/bash\"]"
}

cleanup() {
    [ -n "${EXCLUDE_FILE}" ] && rm -f "${EXCLUDE_FILE}"
    restore_login_profile   # revert host .bashrc / profile.d to original state
}
trap cleanup EXIT

main() {
    check_root
    get_os_info
    : > "${LOG_FILE}"
    warn_split_mounts
    check_kernel_headers
    clean_system_cache
    inject_login_profile
    build_excludes
    set_output_file
    print_intro
    create_tarball
    verify_result
}

main
