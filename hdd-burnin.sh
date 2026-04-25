#!/usr/bin/env bash
#
# hdd-burnin.sh — End-to-end HDD burn-in for large drives (20TB+)
#
# Pipeline per drive (runs in parallel across all drives):
#   1. Collect initial SMART baseline
#   2. SMART short self-test  (~2 min)
#   3. SMART long self-test   (~1-2 days on 28TB)
#   4. badblocks -wsv destructive 4-pattern write+verify  (~4-7 days on 28TB)
#   5. SMART long self-test again
#   6. Final SMART snapshot + diff vs baseline
#
# Inspired by Spearfoot/disk-burnin-and-testing and ezonakiusagi/bht,
# but bundles install + parallel launch + summary in one script.
#
# WARNING: -f mode is DESTRUCTIVE. All data on target drives is erased.
#
set -uo pipefail

VERSION="1.0"
SCRIPT_NAME="$(basename "$0")"

# ---------- Defaults ----------
LOG_DIR="${LOG_DIR:-/var/log/hdd-burnin}"
BB_BLOCK_SIZE=8192      # 28TB needs >=8192 to stay under badblocks' 32-bit block count limit
BB_CONCURRENT=32        # -c: blocks per read/write batch (memory: bs * c)
SMART_POLL_INTERVAL=300 # Seconds between SMART test completion polls
DRY_RUN=1               # Default to dry-run; require -f to actually destroy data
SKIP_INSTALL=0
DRIVES=()

# ---------- Colors ----------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

log()   { printf '%s[%s]%s %s\n' "$C_BLU" "$(date '+%F %T')" "$C_RST" "$*"; }
warn()  { printf '%s[%s] WARN:%s %s\n' "$C_YEL" "$(date '+%F %T')" "$C_RST" "$*" >&2; }
err()   { printf '%s[%s] ERROR:%s %s\n' "$C_RED" "$(date '+%F %T')" "$C_RST" "$*" >&2; }
ok()    { printf '%s[%s] OK:%s %s\n' "$C_GRN" "$(date '+%F %T')" "$C_RST" "$*"; }

usage() {
    cat <<EOF
${C_BLD}$SCRIPT_NAME v$VERSION${C_RST} — End-to-end HDD burn-in

USAGE:
    sudo $SCRIPT_NAME [options] <drive> [drive ...]
    sudo $SCRIPT_NAME [options] --auto          # auto-detect all unmounted HDDs
    sudo $SCRIPT_NAME status                    # show progress of running tests
    sudo $SCRIPT_NAME result [log-dir]          # show pass/fail summary of completed runs

OPTIONS:
    -f, --force         DESTRUCTIVE. Actually run tests (default is dry-run)
    -o, --out DIR       Log directory (default: $LOG_DIR)
    -b, --block SIZE    badblocks block size in bytes (default: $BB_BLOCK_SIZE, needed for 16TB+)
    -c, --count N       badblocks -c value (default: $BB_CONCURRENT)
    --skip-install      Skip apt package installation
    --auto              Auto-detect all non-system, non-mounted HDDs
    -h, --help          This message

EXAMPLES:
    # Dry-run to sanity-check commands:
    sudo $SCRIPT_NAME /dev/sdb /dev/sdc /dev/sdd /dev/sde

    # Actually run destructive burn-in on 4 drives in parallel:
    sudo $SCRIPT_NAME -f /dev/sdb /dev/sdc /dev/sdd /dev/sde

    # Auto-detect and burn-in all candidate drives:
    sudo $SCRIPT_NAME -f --auto

    # Check progress from another terminal:
    sudo $SCRIPT_NAME status

    # Get pass/fail summary after completion:
    sudo $SCRIPT_NAME result

NOTE: 28TB drives take ~5-7 days for badblocks + ~2 days SMART tests.
      Plan for ~10 days total. Drives run warm — verify cooling first.
EOF
}

# ---------- Dependency install ----------
install_deps() {
    if (( SKIP_INSTALL )); then log "Skipping install per --skip-install"; return; fi

    local missing=()
    for cmd in smartctl badblocks lsblk awk grep sed flock; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "All dependencies present."
        return
    fi

    log "Missing tools: ${missing[*]} — installing..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq smartmontools e2fsprogs util-linux coreutils gawk
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q smartmontools e2fsprogs util-linux coreutils gawk
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm smartmontools e2fsprogs util-linux coreutils gawk
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache smartmontools e2fsprogs util-linux coreutils gawk
    else
        err "No supported package manager found. Install smartmontools + e2fsprogs manually."
        exit 1
    fi
    ok "Dependencies installed."
}

# ---------- Safety / discovery ----------
get_drive_info() {
    local drive="$1"
    smartctl -i "$drive" 2>/dev/null | awk -F': +' '
        /Device Model:|Model Number:|Product:/   { model=$2 }
        /Serial Number:|Serial number:/           { serial=$2 }
        /User Capacity:|Total NVM Capacity:/      { cap=$2 }
        END { gsub(/[^A-Za-z0-9._-]/,"_",model); gsub(/[^A-Za-z0-9._-]/,"_",serial);
              printf "%s|%s|%s", model, serial, cap }'
}

is_system_drive() {
    # Refuse to touch any drive holding the root FS or an active mount
    local drive="$1"
    local disk_name
    disk_name="$(basename "$drive")"

    # Is the root FS on this disk?
    local root_src
    root_src="$(findmnt -n -o SOURCE /)"
    if [[ "$root_src" == *"$disk_name"* ]]; then
        return 0
    fi

    # Any partition of this disk currently mounted?
    if lsblk -n -o NAME,MOUNTPOINT "$drive" 2>/dev/null | awk '$2 != "" {found=1} END {exit !found}'; then
        return 0
    fi

    return 1
}

auto_detect_drives() {
    local found=()
    while read -r name type _; do
        [[ "$type" == "disk" ]] || continue
        local dev="/dev/$name"
        # Skip non-rotational (SSDs) if you want; for now include all block disks
        # and rely on is_system_drive to filter
        if is_system_drive "$dev"; then continue; fi
        # Skip NVMe — this script targets SATA/SAS
        [[ "$name" == nvme* ]] && continue
        found+=("$dev")
    done < <(lsblk -d -n -o NAME,TYPE,SIZE)
    printf '%s\n' "${found[@]}"
}

validate_drives() {
    local bad=0
    for d in "${DRIVES[@]}"; do
        if [[ ! -b "$d" ]]; then err "$d is not a block device"; bad=1; continue; fi
        if is_system_drive "$d"; then
            err "$d appears to be a system/mounted drive — REFUSING to touch it"
            bad=1
        fi
    done
    (( bad )) && exit 2
}

confirm_destruction() {
    (( DRY_RUN )) && return 0
    echo ""
    echo "${C_RED}${C_BLD}============================================================${C_RST}"
    echo "${C_RED}${C_BLD}  DESTRUCTIVE OPERATION — ALL DATA WILL BE ERASED${C_RST}"
    echo "${C_RED}${C_BLD}============================================================${C_RST}"
    echo ""
    for d in "${DRIVES[@]}"; do
        local info; info="$(get_drive_info "$d")"
        local model="${info%%|*}"; local rest="${info#*|}"
        local serial="${rest%%|*}"; local cap="${rest#*|}"
        printf "  %s  —  %s / %s / %s\n" "$d" "$model" "$serial" "$cap"
    done
    echo ""
    read -r -p "Type ${C_RED}ERASE${C_RST} to confirm: " answer
    [[ "$answer" == "ERASE" ]] || { err "Aborted."; exit 1; }
}

# ---------- Per-drive burn-in worker ----------
run_smart_test() {
    # $1 drive   $2 short|long   $3 log file
    local drive="$1" kind="$2" logf="$3"
    echo "=== SMART $kind test: start $(date -Iseconds) ===" >>"$logf"
    smartctl -t "$kind" "$drive" >>"$logf" 2>&1

    # Extract polling minutes from smartctl output; fallback by type
    local wait_min
    wait_min="$(smartctl -c "$drive" 2>/dev/null \
        | awk -v k="$kind" '
            tolower($0) ~ "recommended polling time.*" k { for(i=1;i<=NF;i++) if($i ~ /^\([0-9]+$/) { gsub(/[()]/,"",$i); print $i; exit } }')"
    [[ -z "$wait_min" ]] && wait_min=$([[ "$kind" == "short" ]] && echo 5 || echo 1440)

    echo "Polling every ${SMART_POLL_INTERVAL}s; drive reports ~${wait_min} min" >>"$logf"
    sleep $(( wait_min * 60 / 2 ))  # initial wait: half the reported time

    # Poll until self-test completes
    while :; do
        local status
        status="$(smartctl -a "$drive" 2>/dev/null | awk '
            /Self-test execution status:/ { gsub(/.*\(/,""); gsub(/\).*/,""); print; exit }')"
        if ! smartctl -l selftest "$drive" 2>/dev/null \
             | awk 'NR>5 && $2 ~ /(Extended|Short)/ && $3 ~ /offline/ { exit 0 } END { exit 1 }'; then
            # Use simpler check: look for "in progress" vs completed line
            if smartctl -a "$drive" 2>/dev/null | grep -qE "Self-test routine in progress|% of test remaining"; then
                sleep "$SMART_POLL_INTERVAL"
                continue
            fi
        fi
        # Test no longer running
        break
    done

    echo "=== SMART $kind test: finished $(date -Iseconds) ===" >>"$logf"
    smartctl -a "$drive" >>"$logf" 2>&1
}

burn_one_drive() {
    local drive="$1"
    local info; info="$(get_drive_info "$drive")"
    local model="${info%%|*}"; local rest="${info#*|}"
    local serial="${rest%%|*}"
    [[ -z "$model"  ]] && model="UNKNOWN"
    [[ -z "$serial" ]] && serial="$(basename "$drive")"

    local tag="${model}_${serial}"
    local logf="$LOG_DIR/burnin_${tag}.log"
    local bbf="$LOG_DIR/badblocks_${tag}.log"
    local statef="$LOG_DIR/state_${tag}"

    {
        echo "================================================================"
        echo "  HDD Burn-In Log"
        echo "  Drive:  $drive"
        echo "  Model:  $model"
        echo "  Serial: $serial"
        echo "  Host:   $(hostname)"
        echo "  Kernel: $(uname -r)"
        echo "  Start:  $(date -Iseconds)"
        echo "  Dry-run: $DRY_RUN"
        echo "================================================================"
    } >"$logf"

    dry() {
        if (( DRY_RUN )); then
            echo "[DRY-RUN] $*" | tee -a "$logf"
            return 0
        fi
        eval "$@"
    }

    echo "STAGE=baseline" >"$statef"
    echo "" >>"$logf"; echo "--- 1/6 Baseline SMART ---" >>"$logf"
    dry "smartctl -x '$drive' >>'$logf' 2>&1"

    echo "STAGE=smart_short" >"$statef"
    echo "" >>"$logf"; echo "--- 2/6 SMART short test ---" >>"$logf"
    if (( DRY_RUN )); then
        echo "[DRY-RUN] run_smart_test $drive short" >>"$logf"
    else
        run_smart_test "$drive" short "$logf"
    fi

    echo "STAGE=smart_long_1" >"$statef"
    echo "" >>"$logf"; echo "--- 3/6 SMART long test (pre-badblocks) ---" >>"$logf"
    if (( DRY_RUN )); then
        echo "[DRY-RUN] run_smart_test $drive long" >>"$logf"
    else
        run_smart_test "$drive" long "$logf"
    fi

    echo "STAGE=badblocks" >"$statef"
    echo "" >>"$logf"; echo "--- 4/6 badblocks destructive 4-pattern ---" >>"$logf"
    # LANG=C keeps output strings ("Testing with pattern", "Reading and comparing")
    # in English so cmd_status can parse them deterministically across locales.
    local bb_cmd="LANG=C badblocks -b $BB_BLOCK_SIZE -wsv -c $BB_CONCURRENT -o '$bbf' '$drive'"
    echo "+ $bb_cmd" >>"$logf"
    if (( DRY_RUN )); then
        echo "[DRY-RUN] $bb_cmd" >>"$logf"
    else
        # badblocks writes progress to stderr; capture separately, append final status
        if eval "$bb_cmd" >>"$logf" 2>&1; then
            echo "badblocks completed with exit 0" >>"$logf"
        else
            echo "badblocks FAILED with exit $?" >>"$logf"
        fi
    fi

    echo "STAGE=smart_long_2" >"$statef"
    echo "" >>"$logf"; echo "--- 5/6 SMART long test (post-badblocks) ---" >>"$logf"
    if (( DRY_RUN )); then
        echo "[DRY-RUN] run_smart_test $drive long" >>"$logf"
    else
        run_smart_test "$drive" long "$logf"
    fi

    echo "STAGE=final" >"$statef"
    echo "" >>"$logf"; echo "--- 6/6 Final SMART snapshot ---" >>"$logf"
    dry "smartctl -x '$drive' >>'$logf' 2>&1"

    {
        echo ""
        echo "================================================================"
        echo "  End:   $(date -Iseconds)"
        echo "================================================================"
    } >>"$logf"

    echo "STAGE=done" >"$statef"
}

# ---------- Orchestration ----------
launch_parallel() {
    mkdir -p "$LOG_DIR"
    local pids=()
    for d in "${DRIVES[@]}"; do
        log "Launching burn-in for $d → logs in $LOG_DIR"
        ( burn_one_drive "$d" ) &
        pids+=($!)
    done

    echo "${pids[@]}" >"$LOG_DIR/.pids"
    log "All ${#pids[@]} worker(s) started. PIDs: ${pids[*]}"
    log "Monitor progress:  sudo $SCRIPT_NAME status"
    log "Tail a drive log:  tail -f $LOG_DIR/burnin_*.log"

    # Wait for all
    local failures=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then failures=$((failures+1)); fi
    done

    log "All workers finished. $failures failure(s) reported by workers."
    echo ""
    cmd_result "$LOG_DIR"
}

# ---------- Status / summary subcommands ----------
cmd_status() {
    local dir="${1:-$LOG_DIR}"
    if [[ ! -d "$dir" ]]; then err "Log dir $dir not found"; exit 1; fi
    printf "%-40s %-18s %s\n" "DRIVE" "STAGE" "LATEST"
    printf "%-40s %-18s %s\n" "----------------------------------------" "------------------" "----------------"
    for s in "$dir"/state_*; do
        [[ -f "$s" ]] || continue
        local tag="${s##*/state_}"
        local stage; stage="$(cat "$s" 2>/dev/null | sed 's/STAGE=//')"
        local logf="$dir/burnin_${tag}.log"
        local last=""
        [[ -f "$logf" ]] && last="$(tail -n 1 "$logf" 2>/dev/null | cut -c1-60)"
        # If badblocks running, show pass/phase/progress from its log.
        # badblocks separates progress updates with \b (backspace), not newlines —
        # normalise via tr first so grep/tail behave line-oriented.
        if [[ "$stage" == "badblocks" ]]; then
            local clean pat pct phase pass_idx
            clean="$(tr '\b' '\n' <"$logf" 2>/dev/null)"
            pat="$(printf '%s\n' "$clean" | grep -Eo 'Testing with pattern 0x[0-9a-f]{2}' \
                    | tail -n1 | grep -Eo '0x[0-9a-f]{2}')"
            pct="$(printf '%s\n' "$clean" | grep -Eo '[0-9]+\.[0-9]+% done' | tail -n1)"
            if printf '%s\n' "$clean" | grep -E 'Testing with pattern|Reading and comparing' \
                    | tail -n1 | grep -q 'Reading'; then
                phase="verify"
            else
                phase="write"
            fi
            case "$pat" in
                0xaa) pass_idx=1 ;;
                0x55) pass_idx=2 ;;
                0xff) pass_idx=3 ;;
                0x00) pass_idx=4 ;;
                *)    pass_idx="?" ;;
            esac
            [[ -n "$pct" ]] && last="pass ${pass_idx}/4 ${phase} ${pct}"
        fi
        printf "%-40s %-18s %s\n" "$tag" "$stage" "$last"
    done
}

cmd_result() {
    local dir="${1:-$LOG_DIR}"
    if [[ ! -d "$dir" ]]; then err "Log dir $dir not found"; exit 1; fi

    echo ""
    echo "${C_BLD}================= BURN-IN SUMMARY =================${C_RST}"
    printf "%-35s %-10s %-12s %-12s %-12s %s\n" \
        "DRIVE" "RESULT" "REALLOC" "PENDING" "UNCORREC" "BB_ERRORS"
    printf -- "-%.0s" {1..95}; echo

    local overall_pass=0 overall_fail=0
    for logf in "$dir"/burnin_*.log; do
        [[ -f "$logf" ]] || continue
        local tag; tag="$(basename "$logf" .log)"; tag="${tag#burnin_}"
        local bbf="$dir/badblocks_${tag}.log"

        # Extract final SMART attributes from the last "--- 6/6 Final SMART" block
        local smart_tail
        smart_tail="$(awk '/--- 6\/6 Final SMART/{p=1} p' "$logf" 2>/dev/null)"
        [[ -z "$smart_tail" ]] && smart_tail="$(tail -n 200 "$logf")"

        local realloc pending uncorrec
        realloc="$(echo "$smart_tail"  | awk '/Reallocated_Sector_Ct|Reallocated_Event_Count/ { v=$NF } END{print v+0}')"
        pending="$(echo "$smart_tail"  | awk '/Current_Pending_Sector/ { v=$NF } END{print v+0}')"
        uncorrec="$(echo "$smart_tail" | awk '/Offline_Uncorrectable|Reported_Uncorrect/ { v=$NF } END{print v+0}')"

        local bb_errors=0
        if [[ -f "$bbf" ]]; then
            bb_errors="$(wc -l <"$bbf" 2>/dev/null || echo 0)"
            bb_errors="${bb_errors// /}"
        fi

        local result="${C_GRN}PASS${C_RST}"
        if (( realloc > 0 || pending > 0 || uncorrec > 0 || bb_errors > 0 )); then
            result="${C_RED}FAIL${C_RST}"
            overall_fail=$((overall_fail+1))
        else
            overall_pass=$((overall_pass+1))
        fi

        # Truncate long tags for display
        local disp="${tag:0:34}"
        printf "%-35s %-18b %-12s %-12s %-12s %s\n" \
            "$disp" "$result" "$realloc" "$pending" "$uncorrec" "$bb_errors"
    done

    printf -- "-%.0s" {1..95}; echo
    echo "${C_BLD}TOTAL:${C_RST} ${C_GRN}$overall_pass PASS${C_RST}, ${C_RED}$overall_fail FAIL${C_RST}"
    echo ""
    echo "Full logs: $dir/burnin_*.log"
    echo "Any FAIL → consider RMA. Check the raw SMART section of the log."
}

# ---------- Argument parsing ----------
if (( $# == 0 )); then usage; exit 0; fi

case "${1:-}" in
    status)     shift; cmd_status "${1:-$LOG_DIR}"; exit 0 ;;
    result)     shift; cmd_result "${1:-$LOG_DIR}"; exit 0 ;;
    -h|--help)  usage; exit 0 ;;
esac

AUTO=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)     DRY_RUN=0; shift ;;
        -o|--out)       LOG_DIR="$2"; shift 2 ;;
        -b|--block)     BB_BLOCK_SIZE="$2"; shift 2 ;;
        -c|--count)     BB_CONCURRENT="$2"; shift 2 ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        --auto)         AUTO=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        /dev/*)         DRIVES+=("$1"); shift ;;
        *)              err "Unknown arg: $1"; usage; exit 1 ;;
    esac
done

# ---------- Preflight ----------
if [[ $EUID -ne 0 ]]; then err "Must run as root (use sudo)"; exit 1; fi

install_deps

if (( AUTO )); then
    mapfile -t DRIVES < <(auto_detect_drives)
    log "Auto-detected drives: ${DRIVES[*]:-<none>}"
fi

if (( ${#DRIVES[@]} == 0 )); then
    err "No drives specified. Use /dev/sdX or --auto."
    exit 1
fi

validate_drives

log "Target drives: ${DRIVES[*]}"
log "Log directory: $LOG_DIR"
log "Mode: $( (( DRY_RUN )) && echo 'DRY-RUN (use -f to actually run)' || echo 'DESTRUCTIVE')"
log "badblocks: -b $BB_BLOCK_SIZE -wsv -c $BB_CONCURRENT"

confirm_destruction
launch_parallel
