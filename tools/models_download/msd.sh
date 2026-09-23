#!/usr/bin/env bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m' # No Color

trap 'printf "\n%bInterrupted. Re-run to resume.%b\n" "$YELLOW" "$NC"; exit 130' INT

# Format a byte count as a human-readable string (decimal units, matching the ModelScope UI).
human() {
    awk -v b="${1:-0}" 'BEGIN{u="B KB MB GB TB PB";n=split(u,a," ");i=1;
        while(b>=1000&&i<n){b/=1000;i++} printf (i==1?"%d%s":"%.2f%s"),b,a[i]}'
}

display_help() {
    cat << EOF
Usage:
  msd <REPO_ID> [--include include_pattern1 include_pattern2 ...] [--exclude exclude_pattern1 exclude_pattern2 ...] [--token token] [--tool aria2c|wget] [-x threads] [-j jobs] [--dataset] [--local-dir path] [--revision rev]

Description:
  Downloads a model or dataset from ModelScope using the provided repo ID.

Arguments:
  REPO_ID         The ModelScope repo ID (Required)
                  Format: 'org_name/repo_name' (e.g., Qwen/Qwen2.5-0.5B-Instruct)
Options:
  include/exclude_pattern The patterns to match against file path, supports wildcard characters.
                  e.g., '--exclude *.safetensor *.md', '--include vae/*'.
  --token         (Optional) ModelScope access token for gated repos, also read from the
                  MODELSCOPE_API_TOKEN env var. Get it from https://modelscope.cn/my/myaccesstoken
  --tool          (Optional) Download tool to use: aria2c (default) or wget.
  -x              (Optional) Number of download threads for aria2c (default: 4).
  -j              (Optional) Number of concurrent downloads for aria2c (default: 5).
  --dataset       (Optional) Flag to indicate downloading a dataset.
  --local-dir     (Optional) Directory path to store the downloaded data.
                             Defaults to the current directory with a subdirectory named 'repo_name'
                             if REPO_ID is composed of 'org_name/repo_name'.
  --revision      (Optional) Model/Dataset revision to download (default: master).

Example:
  msd Qwen/Qwen2.5-0.5B-Instruct
  msd Qwen/Qwen2.5-0.5B-Instruct --exclude '*.safetensors' -x 8
  msd modelscope/gsm8k --dataset
  msd Eco-Tech/Qwen3.8-Flash-Next-w8a8-mtp -x 8
EOF
    exit 1
}

[[ -z "$1" || "$1" =~ ^-h || "$1" =~ ^--help ]] && display_help

REPO_ID=$1
shift

# Default values
TOOL="aria2c"
THREADS=4
CONCURRENT=5
ENDPOINT=${MODELSCOPE_ENDPOINT:-"https://modelscope.cn"}
TOKEN=${MODELSCOPE_API_TOKEN:-}
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()
REVISION="master"

validate_number() {
    [[ "$2" =~ ^[1-9][0-9]*$ && "$2" -le "$3" ]] || { printf "%b[Error] %s must be 1-%s%b\n" "$RED" "$1" "$3" "$NC"; exit 1; }
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --include) shift; while [[ $# -gt 0 && ! ($1 =~ ^--) && ! ($1 =~ ^-[^-]) ]]; do INCLUDE_PATTERNS+=("$1"); shift; done ;;
        --exclude) shift; while [[ $# -gt 0 && ! ($1 =~ ^--) && ! ($1 =~ ^-[^-]) ]]; do EXCLUDE_PATTERNS+=("$1"); shift; done ;;
        --token) TOKEN="$2"; shift 2 ;;
        --tool)
            [[ "$2" == aria2c || "$2" == wget ]] || { printf "%b[Error] Invalid tool. Use 'aria2c' or 'wget'.%b\n" "$RED" "$NC"; exit 1; }
            TOOL="$2"; shift 2 ;;
        -x) validate_number "threads (-x)" "$2" 10; THREADS="$2"; shift 2 ;;
        -j) validate_number "concurrent downloads (-j)" "$2" 10; CONCURRENT="$2"; shift 2 ;;
        --dataset) DATASET=1; shift ;;
        --local-dir) LOCAL_DIR="$2"; shift 2 ;;
        --revision) REVISION="$2"; shift 2 ;;
        *) display_help ;;
    esac
done

# A fingerprint of the options that affect the file list; a change forces regeneration.
generate_command_string() {
    printf 'REPO_ID=%s TOOL=%s INCLUDE=%s EXCLUDE=%s DATASET=%s TOKEN=%s ENDPOINT=%s REVISION=%s' \
        "$REPO_ID" "$TOOL" "${INCLUDE_PATTERNS[*]}" "${EXCLUDE_PATTERNS[*]}" "${DATASET:-0}" \
        "${TOKEN:-}" "${ENDPOINT:-}" "$REVISION"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        printf "%b%s is not installed. Please install it first.%b\n" "$RED" "$1" "$NC"
        exit 1
    fi
}

check_command curl; check_command "$TOOL"

LOCAL_DIR="${LOCAL_DIR:-${REPO_ID#*/}}"
mkdir -p "$LOCAL_DIR/.msd"

# The ModelScope resolve URL carries the models|datasets prefix (huggingface.co does not).
REPO_API_PATH="models/$REPO_ID"
[[ "$DATASET" == 1 ]] && REPO_API_PATH="datasets/$REPO_ID"
DOWNLOAD_API_PATH="$REPO_API_PATH"

# wget --cut-dirs strips "<download_api_path>/resolve/<revision>/".
CUT_DIRS=$(( $(printf '%s' "$DOWNLOAD_API_PATH" | tr -cd '/' | wc -c) + 3 ))

# One request lists the whole repo (no pagination): models use repo/files, datasets use repo/tree.
LIST_URL="$ENDPOINT/api/v1/$REPO_API_PATH"
if [[ "$DATASET" == 1 ]]; then
    LIST_URL="$LIST_URL/repo/tree?Revision=$REVISION&Recursive=True"
else
    LIST_URL="$LIST_URL/repo/files?Revision=$REVISION&Recursive=true"
fi

# ModelScope auth: the official SDK exchanges the token for session cookies (cookie-based
# login); the jar then serves the listing and download requests.
COOKIE_JAR="$LOCAL_DIR/.msd/ms_cookies"
COOKIE_STR=""
if [[ -n "$TOKEN" ]]; then
    printf "%bLogging in to ModelScope...%b\n" "$DIM" "$NC"
    login_code=$(curl -sSL -c "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -d "{\"AccessToken\":\"$TOKEN\"}" "$ENDPOINT/api/v1/login")
    [[ "$login_code" == "200" ]] || { printf "%b[Error] ModelScope login failed (HTTP %s). Check the token.%b\n" "$RED" "$login_code" "$NC"; exit 1; }
    COOKIE_STR=$(awk '!/^#/ && NF>=7 {printf "%s=%s; ", $6, $7}' "$COOKIE_JAR"); COOKIE_STR=${COOKIE_STR%; }
fi

printf "%b%s%b (%s, %s)\n" "$BOLD" "$REPO_ID" "$NC" "$REVISION" "$ENDPOINT"

# Emit "size<TAB>path" for every file in the listing response. Business errors keep HTTP 200,
# so the body's Code must be checked; files carry Type "blob" (the jq path filters them).
fetch_ms_files() {
    local page="$LOCAL_DIR/.msd/tree_page.json" code msg
    code=$(curl -sSL ${TOKEN:+-b "$COOKIE_JAR"} -o "$page" -w '%{http_code}' "$LIST_URL") || return 1
    if [[ "$code" != "200" ]] || ! grep -q '"Code":200' "$page"; then
        msg=$(grep -oE '"Message":"[^"]*"' "$page" 2>/dev/null | head -1 | sed 's/.*"Message":"//; s/"$//')
        printf "%b[Error] Failed to list repository files from %s (HTTP %s)%s%b\n" \
            "$RED" "$LIST_URL" "$code" "${msg:+: $msg}" "$NC" >&2
        return 1
    fi
    if command -v jq &>/dev/null; then
        jq -r '.Data.Files[]? | select(.Type=="blob") | "\(.Size)\t\(.Path)"' "$page"
    else
        # No jq: entries are flat objects, but key order differs between models' repo/files
        # and datasets' repo/tree, so extract each field per entry.
        tr -d '\n' < "$page" | sed 's/.*"Files"://' \
            | grep -oE '\{[^{}]*\}' \
            | while IFS= read -r entry; do
                [[ "$entry" != *'"Type":"blob"'* ]] && continue
                p=$(printf '%s' "$entry" | grep -oE '"Path":"[^"]*"' | head -1 | sed 's/.*"Path":"//; s/"$//')
                s=$(printf '%s' "$entry" | grep -oE '"Size":[0-9]+' | head -1 | grep -o '[0-9]*')
                printf '%s\t%s\n' "$s" "$p"
              done
    fi
}

# Reuse the cached list only if the command is unchanged AND the manifest is intact (its line
# count equals repo_info's total). A failed/aborted listing leaves no repo_info, so it re-lists.
should_regenerate_filelist() {
    local cmd="$LOCAL_DIR/.msd/last_download_command" mf="$LOCAL_DIR/.msd/manifest" info="$LOCAL_DIR/.msd/repo_info"
    [[ -f "$mf" && -f "$info" && "$(generate_command_string)" == "$(cat "$cmd" 2>/dev/null)" \
       && "$(wc -l < "$mf")" == "$(cut -d' ' -f1 "$info" 2>/dev/null)" ]] && return 1
    return 0
}

fileslist_file=".msd/${TOOL}_urls.txt"

# Convert a list of wildcard patterns into a single alternation regex.
patterns_to_regex() {
    (($#)) || return 0
    printf '%s\n' "$@" | sed 's/\./\\./g; s/\*/.*/g' | paste -sd '|' -
}

# Keep only "size<TAB>path" stdin lines matching include/exclude (the *_REGEX globals).
filter_size_path() {
    local size path
    while IFS=$'\t' read -r size path; do
        [[ -z "$path" ]] && continue
        [[ -n "$INCLUDE_REGEX" && ! "$path" =~ $INCLUDE_REGEX ]] && continue
        [[ -n "$EXCLUDE_REGEX" && "$path" =~ $EXCLUDE_REGEX ]] && continue
        printf '%s\t%s\n' "${size:-0}" "$path"
    done
}

# Dedup .msd/manifest.partial by path into the final manifest, and write "<count> <bytes>"
# totals to filelist_stats.
finalize_filelist() {
    local mf="$LOCAL_DIR/.msd/manifest"
    : > "$mf"
    awk -F'\t' -v mf="$mf" '!seen[$2]++ { print >> mf; n++; s+=$1 } END { print (n+0)" "(s+0) }' \
        "$LOCAL_DIR/.msd/manifest.partial" > "$LOCAL_DIR/.msd/filelist_stats"
}

# Build tool input from the manifest; set NEED_COUNT (files still to fetch). One find pass diffs
# the tree, keeping files missing or the wrong size (.aria2 sidecar = in-progress, kept): cheap
# for huge repos, correct after a manual delete. Run from the local dir (manifest paths relative).
build_download_list() {
    local needed=.msd/needed size path dir cur
    if [[ ! -s .msd/manifest ]]; then NEED_COUNT=0; : > "$fileslist_file"; return; fi
    awk -F'\t' '
        FNR==NR { want[$2]=$1; ord[++n]=$2; next }
        { p=$2; sub(/^\.\//,"",p);
          if (p ~ /\.aria2$/) { sub(/\.aria2$/,"",p); part[p]=1 } else have[p]=$1 }
        END { for (i=1;i<=n;i++) { q=ord[i];
                if ((q in have) && have[q]==want[q] && !(q in part)) continue;
                print want[q] "\t" q } }
    ' .msd/manifest <(find . -type f ! -path './.msd/*' -printf '%s\t%p\n' 2>/dev/null) > "$needed"
    NEED_COUNT=$(wc -l < "$needed")
    # Per needed file: drop a wrong-size copy -c/--continue can't fix in place (aria2c with no
    # .aria2 control file, or a wget file larger than expected) for a fresh refetch; emit the record.
    while IFS=$'\t' read -r size path; do
        [[ -z "$path" ]] && continue
        if [[ "$TOOL" == "aria2c" ]]; then
            [[ -e "$path" && ! -e "$path.aria2" ]] && rm -f "$path"
            dir="${path%/*}"; [[ "$dir" == "$path" ]] && dir=""
            printf '%s/%s/resolve/%s/%s\n dir=%s\n out=%s\n' "$ENDPOINT" "$DOWNLOAD_API_PATH" "$REVISION" "$path" "$dir" "${path##*/}"
            [[ -n "$COOKIE_STR" ]] && printf ' header=Cookie: %s\n' "$COOKIE_STR"
            printf '\n'
        else
            cur=$(stat -c%s "$path" 2>/dev/null || echo 0); (( cur > size )) && rm -f "$path"
            printf '%s/%s/resolve/%s/%s\n' "$ENDPOINT" "$DOWNLOAD_API_PATH" "$REVISION" "$path"
        fi
    done < "$needed" > "$fileslist_file"
    rm -f "$needed"
}

if should_regenerate_filelist; then
    command -v jq &>/dev/null || printf "%b[Warning] jq not installed, using grep/awk for json parsing (slower). Consider installing jq.%b\n" "$YELLOW" "$NC"
    INCLUDE_REGEX=$(patterns_to_regex "${INCLUDE_PATTERNS[@]}")
    EXCLUDE_REGEX=$(patterns_to_regex "${EXCLUDE_PATTERNS[@]}")
    printf "%bListing files...%b" "$DIM" "$NC"
    fetch_ms_files | filter_size_path > "$LOCAL_DIR/.msd/manifest.partial"
    gen_status=${PIPESTATUS[0]}
    (( gen_status == 0 )) || { printf "\n%b[Error] Failed to list repository files.%b\n" "$RED" "$NC" >&2; exit 1; }
    finalize_filelist
    read -r TOTAL_FILES SUM_SIZE < "$LOCAL_DIR/.msd/filelist_stats"
    printf '\r\033[K%bListed %d files (%s)%b\n' "$DIM" "$TOTAL_FILES" "$(human "$SUM_SIZE")" "$NC"
    printf '%s %s\n' "$TOTAL_FILES" "$SUM_SIZE" > "$LOCAL_DIR/.msd/repo_info"
    # Fingerprint written last: marks the list complete (an interrupted listing has none, so it re-lists).
    generate_command_string > "$LOCAL_DIR/.msd/last_download_command"
    rm -f "$LOCAL_DIR/.msd/manifest.partial" "$LOCAL_DIR/.msd/tree_page.json"
fi

cd "$LOCAL_DIR" || exit 1

# Render one in-place status line; speed = byte delta since last call (PREV_B/PREV_T).
# Fields are fixed-width so columns don't jitter as values grow a digit; ETA is last.
PREV_B=0; PREV_T=0
render_progress() {
    local now=$1 dfiles=$2 dt sp pct eta e
    dt=$(( SECONDS - PREV_T )); ((dt<1)) && dt=1
    sp=$(( (now - PREV_B) / dt )); ((sp<0)) && sp=0; PREV_B=$now; PREV_T=$SECONDS
    pct=0; ((TOTAL_SIZE>0)) && pct=$(( now * 100 / TOTAL_SIZE )); ((pct>100)) && pct=100
    # ETA only once speed is meaningful; clamp absurd early estimates to keep it tidy.
    eta="--:--"; ((sp>0 && TOTAL_SIZE>now)) && { e=$(( (TOTAL_SIZE-now)/sp )); ((e<360000)) && eta=$(printf '%02d:%02d' $((e/60)) $((e%60))); }
    printf '\r\033[K%b[%3d%%]%b %*d/%d files | %9s/%9s | %9s/s | ETA %s' \
        "$GREEN" "$pct" "$NC" "${#TOTAL_FILES}" "$dfiles" "$TOTAL_FILES" \
        "$(human "$now")" "$(human "$TOTAL_SIZE")" "$(human "$sp")" "$eta"
}

# Progress without scanning finished files: manifest totals + a stat of only in-flight files.
monitor_progress() {
    local interval=$1 base=$1 stop_hint="Stopping download, please wait..."; PREV_T=$SECONDS
    # The main INT trap is deferred until the foreground download returns, so acknowledge
    # Ctrl+C here (fires at once in the subshell) and note the force-stop that already works.
    [[ "$TOOL" == "aria2c" ]] && stop_hint="Stopping download, please wait... (press Ctrl+C again to force stop)"
    trap 'printf "\n%b%s%b\n" "$YELLOW" "$stop_hint" "$NC"; exit 0' INT
    if [[ "$TOOL" == "wget" ]]; then
        # wget downloads in manifest order, so a forward cursor needs to stat only the
        # current file; everything before it is done and counted by its known size.
        local -a MS MP; local s p
        while IFS=$'\t' read -r s p; do MS+=("$s"); MP+=("$p"); done < .msd/manifest
        local idx=0 done_b=0 cur
        while :; do
            sleep "$interval"
            while (( idx < ${#MP[@]} )); do
                cur=$(stat -c%s "${MP[idx]}" 2>/dev/null) || break
                (( cur >= MS[idx] )) || break
                done_b=$(( done_b + MS[idx] )); idx=$((idx+1))
            done
            cur=0; (( idx < ${#MP[@]} )) && cur=$(stat -c%s "${MP[idx]}" 2>/dev/null || echo 0)
            render_progress $(( done_b + cur )) "$idx"
        done
    else
        # Parallel downloads finish out of order, so a cursor would miss files completing between
        # ticks. Each tick sums block usage (sparse-aware) of the manifest's files only — ignoring
        # stale files left from an earlier version of the repo — minus in-progress (.aria2) ones.
        local now files t0 walk
        while :; do
            sleep "$interval"
            t0=$SECONDS
            read -r now files < <(awk -F'\t' '
                FNR==NR { want[$2]=1; next }
                { p=$2; sub(/^\.\//,"",p)
                  if (p ~ /\.aria2$/) { sub(/\.aria2$/,"",p); if (p in want) a++; next }
                  if (p in want) { b+=$1; d++ } }
                END { print b*512, d-a }
            ' .msd/manifest <(find . -type f ! -path './.msd/*' -printf '%b\t%p\n' 2>/dev/null))
            render_progress "$now" "$files"
            # Self-throttle: if the walk took longer than the base interval, sleep that long
            # next time so scanning stays under ~half the wall-clock at any repo size.
            walk=$(( SECONDS - t0 )); interval=$base; (( walk > base )) && interval=$walk
        done
    fi
}

# Totals were persisted at file-list generation; reload for resumed runs.
[[ -f .msd/repo_info ]] && read -r TOTAL_FILES TOTAL_SIZE < .msd/repo_info
TOTAL_FILES=${TOTAL_FILES:-0}; TOTAL_SIZE=${TOTAL_SIZE:-0}
FILE_NOUN="files"; ((TOTAL_FILES==1)) && FILE_NOUN="file"

# Diff the local tree against the manifest to find what's missing, then short-circuit if done.
((TOTAL_FILES>50000)) && printf "%bChecking local files...%b\n" "$DIM" "$NC"
build_download_list
if (( NEED_COUNT == 0 )); then
    printf "%bUp to date. %s %s in %s%b\n" "$GREEN" "$TOTAL_FILES" "$FILE_NOUN" "$LOCAL_DIR" "$NC"
    exit 0
fi

# "Resuming" if any data is already on disk (completed files or a partial), else a fresh start.
verb="Downloading"; [[ -n "$(find . -type f ! -path './.msd/*' -print -quit 2>/dev/null)" ]] && verb="Resuming"
printf "%s %s %s to %s  ·  Ctrl+C to stop, re-run to resume\n" "$verb" "$TOTAL_FILES" "$FILE_NOUN" "$LOCAL_DIR"

# Silence native per-file output (logged to .msd/download.log) so the monitor owns one
# clean line. Refresh every 1s, backing off for huge repos where the walk gets expensive.
interval=1; ((TOTAL_FILES>50000)) && interval=5
monitor_progress "$interval" &
MON_PID=$!
trap 'kill "$MON_PID" 2>/dev/null' EXIT

if [[ "$TOOL" == "aria2c" ]]; then
    aria2c --quiet=true --log=.msd/download.log --log-level=error --file-allocation=none \
        -x "$THREADS" -j "$CONCURRENT" -s "$THREADS" -k 1M -c -i "$fileslist_file" >/dev/null
    status=$?
else
    wget -x -nH --cut-dirs="$CUT_DIRS" ${TOKEN:+--cookie="$COOKIE_STR"} \
        --input-file="$fileslist_file" --continue -nv -o .msd/download.log
    status=$?
fi

# Clear the live progress line in place; the final status line takes its spot (no blank line).
kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null; printf '\r\033[K'

if [[ $status -eq 0 ]]; then
    printf "%bDone. %s %s, %s in %s%b\n" "$GREEN" "$TOTAL_FILES" "$FILE_NOUN" "$(human "$TOTAL_SIZE")" "$LOCAL_DIR" "$NC"
else
    printf "%bDownload incomplete. Re-run to resume. Log: %s%b\n" "$RED" "$PWD/.msd/download.log" "$NC"
    exit 1
fi
