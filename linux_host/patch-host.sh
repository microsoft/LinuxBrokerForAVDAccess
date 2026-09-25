#!/bin/bash

# Usage: ./patch-host.sh start <security|all> [TOKEN]
#        ./patch-host.sh status
#        ./patch-host.sh run <security|all> [TOKEN]      (internal: the detached run)
#
# Lets the broker patch a host during a maintenance run without broader sudo rights. It
# follows manage-lease.sh: every argument is validated here, and the API reads the result
# from the __PATCH_HOST_*= lines.
#
# `start` detaches the package upgrade, through systemd-run or else setsid, so the broker's
# SSH call returns at once, and `status` reports how it is going. A start that carries the
# token of the run already recorded only reports it, so the broker can safely repeat a start
# whose answer it never received. The broker restarts the host itself once the run succeeds,
# so a run only succeeds when the kernel the host boots next has a usable initramfs; when /boot
# is too small for another kernel, the run keeps two kernels rather than the default three.
#
# The package manager is dnf on RHEL 8 and 9, yum on RHEL 7 and apt on Ubuntu, where both
# modes keep configuration files that were changed locally. After every run, xrdp is pointed
# at xrdp-startwm.sh again in case the run replaced its sesman.ini. Output goes to
# /var/log/linuxbroker-patch.log; the state of the last run is kept under
# /var/lib/linuxbroker-release-session.

set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The Linux Broker host agent version. Every script in linux_host/ declares the same value
# and the heartbeat reports it; bump them together with HOST_AGENT_VERSION in api/config.py.
LINUXBROKER_AGENT_VERSION="1.1.0"

STATE_DIRECTORY="/var/lib/linuxbroker-release-session"
STATE_FILE="$STATE_DIRECTORY/patch-state"
LOCK_FILE="$STATE_DIRECTORY/patch.lock"
RUN_LOCK_FILE="$STATE_DIRECTORY/patch-run.lock"
LOG_FILE="/var/log/linuxbroker-patch.log"
LOG_KEEP_BYTES=1000000
LOG_MAX_BYTES=5000000
UNIT_PREFIX="linuxbroker-patch"
# A run that has not recorded its process yet is still starting for this long.
START_GRACE_SECONDS=60
SUMMARY_MAX_CHARS=200
XRDP_STARTWM_SCRIPT="/usr/local/bin/xrdp-startwm.sh"
LAUNCHER_LOG_TAG="xrdp-startwm.sh:"

usage() {
    echo "Usage: $0 start <security|all> [TOKEN]" >&2
    echo "       $0 status" >&2
    exit 2
}

result() {
    printf '__PATCH_HOST_%s=%s\n' "$1" "$2"
}

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

validate_mode() {
    if [ "$1" != "security" ] && [ "$1" != "all" ]; then
        echo "Invalid mode." >&2
        exit 2
    fi
}

validate_token() {
    if [ -n "$1" ] && [[ ! "$1" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
        echo "Invalid token." >&2
        exit 2
    fi
}

script_path() {
    readlink -f "$0" 2>/dev/null || echo "$0"
}

# Reads the recorded state into STATE_* variables. Only known keys with safe values are
# taken, so a damaged file can never inject anything.
load_state() {
    STATE_STATE="none"
    STATE_MODE=""
    STATE_TOKEN=""
    STATE_STARTED_AT=""
    STATE_FINISHED_AT=""
    STATE_EXIT_CODE=""
    STATE_MANAGER=""
    STATE_UNIT=""
    STATE_PID=""

    [ -f "$STATE_FILE" ] || return 0

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            STATE) [[ "$value" =~ ^(running|succeeded|failed)$ ]] && STATE_STATE="$value" ;;
            MODE) [[ "$value" =~ ^(security|all)$ ]] && STATE_MODE="$value" ;;
            TOKEN) [[ "$value" =~ ^[A-Za-z0-9-]{1,64}$ ]] && STATE_TOKEN="$value" ;;
            STARTED_AT) [[ "$value" =~ ^[0-9]{1,12}$ ]] && STATE_STARTED_AT="$value" ;;
            FINISHED_AT) [[ "$value" =~ ^[0-9]{1,12}$ ]] && STATE_FINISHED_AT="$value" ;;
            EXIT_CODE) [[ "$value" =~ ^[0-9]{1,3}$ ]] && STATE_EXIT_CODE="$value" ;;
            MANAGER) [[ "$value" =~ ^(dnf|yum|apt)$ ]] && STATE_MANAGER="$value" ;;
            UNIT) [[ "$value" =~ ^$UNIT_PREFIX-[0-9]{1,12}$ ]] && STATE_UNIT="$value" ;;
            PID) [[ "$value" =~ ^[0-9]{1,10}$ ]] && STATE_PID="$value" ;;
        esac
    done < "$STATE_FILE"
}

# Writes the state atomically, so a reader never sees half a file.
save_state() {
    local temporary="$STATE_FILE.tmp.$$"
    {
        printf 'STATE=%s\n' "$STATE_STATE"
        printf 'MODE=%s\n' "$STATE_MODE"
        printf 'TOKEN=%s\n' "$STATE_TOKEN"
        printf 'STARTED_AT=%s\n' "$STATE_STARTED_AT"
        printf 'FINISHED_AT=%s\n' "$STATE_FINISHED_AT"
        printf 'EXIT_CODE=%s\n' "$STATE_EXIT_CODE"
        printf 'MANAGER=%s\n' "$STATE_MANAGER"
        printf 'UNIT=%s\n' "$STATE_UNIT"
        printf 'PID=%s\n' "$STATE_PID"
    } > "$temporary" && chmod 600 "$temporary" && mv -f "$temporary" "$STATE_FILE"
}

with_lock() {
    mkdir -p "$STATE_DIRECTORY"
    exec 9> "$LOCK_FILE"
    flock -w 30 9 || { echo "Another patch-host.sh call holds the lock." >&2; exit 1; }
}

# Whether the recorded run is still going. A run whose unit and process are both gone, and
# that never recorded how it ended, was interrupted, for example by a restart.
run_is_alive() {
    local state

    if [ -n "$STATE_UNIT" ] && command -v systemctl >/dev/null 2>&1; then
        state=$(systemctl is-active "$STATE_UNIT" 2>/dev/null)
        case "$state" in
            active|activating|reloading) return 0 ;;
        esac
    fi

    if [ -n "$STATE_PID" ] && kill -0 "$STATE_PID" 2>/dev/null \
        && tr '\0' ' ' < "/proc/$STATE_PID/cmdline" 2>/dev/null | grep -q 'patch-host.sh'; then
        return 0
    fi

    if [ -z "$STATE_PID" ] && [ -n "$STATE_STARTED_AT" ] \
        && [ $(( $(date +%s) - STATE_STARTED_AT )) -lt "$START_GRACE_SECONDS" ]; then
        return 0
    fi

    return 1
}

current_state() {
    if [ "$STATE_STATE" = "running" ]; then
        if run_is_alive; then
            echo running
        else
            echo interrupted
        fi
    else
        echo "$STATE_STATE"
    fi
}

reboot_required() {
    if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
        echo yes
        return
    fi
    if command -v needs-restarting >/dev/null 2>&1; then
        if needs-restarting -r >/dev/null 2>&1; then
            echo no
        else
            # Exit 1 means a restart is needed; anything else could not tell.
            [ $? -eq 1 ] && echo yes || echo unknown
        fi
        return
    fi
    # Ubuntu always writes reboot-required when it needs one.
    if [ "$(package_manager)" = "apt" ]; then
        echo no
    else
        echo unknown
    fi
}

# The last line the package manager wrote, for the broker to show when a run failed.
failure_summary() {
    [ -f "$LOG_FILE" ] || return 0
    tail -n 50 "$LOG_FILE" 2>/dev/null \
        | LC_ALL=C tr -d '\000-\010\013-\037\177' \
        | grep -v '^[[:space:]]*$' \
        | grep -v -e ' - Patch run ' -e " - $LAUNCHER_LOG_TAG " \
        | tail -n 1 \
        | cut -c "1-$SUMMARY_MAX_CHARS"
}

report_status() {
    local state

    state=$(current_state)
    result STATE "$state"
    result MODE "$STATE_MODE"
    result TOKEN "$STATE_TOKEN"
    result MANAGER "$STATE_MANAGER"
    result STARTED_AT "$STATE_STARTED_AT"
    result FINISHED_AT "$STATE_FINISHED_AT"
    result EXIT_CODE "$STATE_EXIT_CODE"
    result REBOOT_REQUIRED "$(reboot_required)"
    if [ "$state" = "failed" ] || [ "$state" = "interrupted" ]; then
        result SUMMARY "$(failure_summary)"
    fi
}

package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    elif command -v apt-get >/dev/null 2>&1; then
        echo apt
    fi
}

trim_log() {
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
        tail -c "$LOG_KEEP_BYTES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

boot_free_mb() {
    df -Pm /boot 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# What a kernel takes in /boot, judged by the running one: its image, its initramfs and any
# kdump initramfs, rounded up to whole megabytes.
kernel_footprint_mb() {
    local running
    local file
    local bytes=0

    running=$(uname -r)
    for file in "/boot/vmlinuz-$running" "/boot/initramfs-$running.img" "/boot/initramfs-${running}kdump.img"; do
        if [ -f "$file" ]; then
            bytes=$((bytes + $(stat -c %s "$file" 2>/dev/null || echo 0)))
        fi
    done
    echo $(((bytes + 1048575) / 1048576))
}

# dnf and yum keep three kernels by default, but the /boot of an Azure RHEL image holds two
# at most: each initramfs is about 256 MB. When the next kernel would not fit, the run keeps
# two, so the oldest kernel (never the running one) is removed in the same transaction,
# before the new initramfs is written.
kernel_limit_option() {
    local free
    local needed

    free=$(boot_free_mb)
    needed=$(($(kernel_footprint_mb) + 50))
    if [ -n "$free" ] && [ "$free" -lt "$needed" ]; then
        log "/boot has $free MB free and a kernel needs about $needed MB, so this run keeps two kernels: the running one and the newest."
        echo "--setopt=installonly_limit=2"
    fi
}

# The kernel the host boots next: the default on RHEL, the newest on Ubuntu.
next_boot_kernel() {
    local path

    if command -v grubby >/dev/null 2>&1; then
        path=$(grubby --default-kernel 2>/dev/null)
        if [ -n "$path" ]; then
            basename "$path" | sed 's/^vmlinuz-//'
            return 0
        fi
    fi
    find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*rescue*' -printf '%f\n' 2>/dev/null \
        | sed 's/^vmlinuz-//' | sort -V | tail -n 1
}

initramfs_path() {
    if [ "$1" = "apt" ]; then
        echo "/boot/initrd.img-$2"
    else
        echo "/boot/initramfs-$2.img"
    fi
}

initramfs_is_valid() {
    [ -s "$1" ] || return 1
    if command -v lsinitrd >/dev/null 2>&1; then
        lsinitrd "$1" >/dev/null 2>&1
    elif command -v lsinitramfs >/dev/null 2>&1; then
        lsinitramfs "$1" >/dev/null 2>&1
    fi
}

# rpm does not fail a transaction when a scriptlet fails, so a full /boot can leave the new
# default kernel without an initramfs while dnf reports success, and the next boot then stops
# in GRUB. The broker restarts a host only after a successful run, so a run succeeds only when
# the kernel the host boots next can start. Otherwise the running kernel stays the default.
verify_next_boot() {
    local manager="$1"
    local version
    local image
    local running

    version=$(next_boot_kernel)
    [ -n "$version" ] || return 0
    image=$(initramfs_path "$manager" "$version")
    initramfs_is_valid "$image" && return 0

    log "The kernel the host boots next, $version, has no usable initramfs at $image. Building it."
    if [ "$manager" = "apt" ]; then
        if [ -e "$image" ]; then
            update-initramfs -u -k "$version" >> "$LOG_FILE" 2>&1
        else
            update-initramfs -c -k "$version" >> "$LOG_FILE" 2>&1
        fi
    else
        dracut -f "$image" "$version" >> "$LOG_FILE" 2>&1
    fi
    if initramfs_is_valid "$image"; then
        log "Built $image."
        return 0
    fi
    rm -f "$image"

    running=$(uname -r)
    if [ "$version" != "$running" ] && command -v grubby >/dev/null 2>&1 && [ -s "/boot/vmlinuz-$running" ]; then
        if grubby --set-default "/boot/vmlinuz-$running" >> "$LOG_FILE" 2>&1; then
            log "Made the running kernel, $running, the default again, so the host still boots."
        fi
    fi
    log "Could not build the initramfs for $version; /boot has $(boot_free_mb) MB free. Free space in /boot, for example by removing an old kernel, then patch again."
    return 1
}

start() {
    local mode="$1"
    local token="$2"
    local manager
    local now
    local unit=""

    with_lock
    load_state

    if [ -n "$token" ] && [ "$STATE_TOKEN" = "$token" ] && [ "$STATE_STATE" != "none" ]; then
        result RESULT already-started
        report_status
        return 0
    fi

    if [ "$STATE_STATE" = "running" ] && run_is_alive; then
        result RESULT busy
        report_status
        return 0
    fi

    manager=$(package_manager)
    if [ -z "$manager" ]; then
        echo "No supported package manager (dnf, yum or apt-get) was found." >&2
        result RESULT unsupported
        exit 1
    fi

    now=$(date +%s)
    trim_log
    STATE_STATE="running"
    STATE_MODE="$mode"
    STATE_TOKEN="$token"
    STATE_STARTED_AT="$now"
    STATE_FINISHED_AT=""
    STATE_EXIT_CODE=""
    STATE_MANAGER="$manager"
    STATE_PID=""
    STATE_UNIT=""

    # A transient unit outlives the SSH session and is stopped cleanly on shutdown. Each run
    # gets its own name, because systemd before 236 keeps a failed unit loaded.
    if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1; then
        unit="$UNIT_PREFIX-$now"
        STATE_UNIT="$unit"
    fi
    save_state || { result RESULT failed; exit 1; }

    log "Patch run requested: mode=$mode manager=$manager${token:+ token=$token}."
    # Through bash, so the run does not depend on the script's execute bit.
    if [ -n "$unit" ] && systemd-run --unit="$unit" --description="Linux Broker patch run" --quiet \
        /bin/bash "$(script_path)" run "$mode" ${token:+"$token"} >/dev/null 2>&1; then
        result RESULT started
    else
        STATE_UNIT=""
        save_state
        setsid /bin/bash "$(script_path)" run "$mode" ${token:+"$token"} >/dev/null 2>&1 < /dev/null &
        result RESULT started
    fi

    report_status
}

status() {
    with_lock
    load_state
    report_status
}

# unattended-upgrade takes dpkg's options only from the apt configuration, and without these
# it holds back a package whose update would ask about a configuration file that was changed
# locally, such as xrdp's sesman.ini.
apt_security_upgrade() {
    local config status=0

    config=$(mktemp) || return 1
    printf 'Dpkg::Options { "--force-confdef"; "--force-confold"; };\n' > "$config"
    APT_CONFIG="$config" unattended-upgrade -v || status=$?
    rm -f "$config"
    return "$status"
}

# Points xrdp at the launcher again in case the run replaced sesman.ini. Whatever the launcher
# reports is marked, so the failure summary still shows the upgrade's own last line, and it
# never changes the result of the run.
reinstall_launcher() {
    local output
    local line
    local status=0

    [ -x "$XRDP_STARTWM_SCRIPT" ] || return 0
    output=$("$XRDP_STARTWM_SCRIPT" --install 2>&1) || status=$?
    while IFS= read -r line; do
        [ -n "$line" ] && log "$LAUNCHER_LOG_TAG $line"
    done <<< "$output"
    log "$LAUNCHER_LOG_TAG --install exited with $status."
    return 0
}

# The upgrade itself, in the detached unit or session.
run() {
    local mode="$1"
    local token="$2"
    local manager
    local keep=""
    local code=0

    mkdir -p "$STATE_DIRECTORY"
    exec 8> "$RUN_LOCK_FILE"
    if ! flock -n 8; then
        log "A patch run is already in progress; not starting another."
        exit 1
    fi

    with_lock
    load_state
    if [ "$STATE_TOKEN" != "$token" ]; then
        STATE_TOKEN="$token"
        STATE_MODE="$mode"
        STATE_STARTED_AT=$(date +%s)
    fi
    STATE_STATE="running"
    STATE_PID="$$"
    manager=$(package_manager)
    STATE_MANAGER="$manager"
    save_state
    flock -u 9

    log "Patch run started: mode=$mode manager=${manager:-none}."
    case "$manager" in
        dnf)
            keep=$(kernel_limit_option)
            if [ "$mode" = "security" ]; then
                dnf -y upgrade --security --refresh ${keep:+"$keep"} >> "$LOG_FILE" 2>&1 || code=$?
            else
                dnf -y upgrade --refresh ${keep:+"$keep"} >> "$LOG_FILE" 2>&1 || code=$?
            fi
            ;;
        yum)
            keep=$(kernel_limit_option)
            if [ "$mode" = "security" ]; then
                yum -y update --security ${keep:+"$keep"} >> "$LOG_FILE" 2>&1 || code=$?
            else
                yum -y update ${keep:+"$keep"} >> "$LOG_FILE" 2>&1 || code=$?
            fi
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get -o DPkg::Lock::Timeout=600 update >> "$LOG_FILE" 2>&1 || code=$?
            if [ "$code" -eq 0 ]; then
                if [ "$mode" = "security" ]; then
                    if command -v unattended-upgrade >/dev/null 2>&1; then
                        apt_security_upgrade >> "$LOG_FILE" 2>&1 || code=$?
                    else
                        log "unattended-upgrades is not installed, so security updates alone cannot be applied. Use all updates instead."
                        code=3
                    fi
                else
                    apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                        -y --with-new-pkgs upgrade >> "$LOG_FILE" 2>&1 || code=$?
                fi
            fi
            ;;
        *)
            log "No supported package manager was found."
            code=4
            ;;
    esac

    # Checked whatever the upgrade returned: a failed one can leave a broken default too.
    if [ -n "$manager" ] && ! verify_next_boot "$manager"; then
        [ "$code" -eq 0 ] && code=5
    fi

    reinstall_launcher

    with_lock
    load_state
    if [ "$code" -eq 0 ]; then
        STATE_STATE="succeeded"
    else
        STATE_STATE="failed"
    fi
    STATE_EXIT_CODE="$code"
    STATE_FINISHED_AT=$(date +%s)
    STATE_PID=""
    save_state
    log "Patch run ended: ${STATE_STATE} (exit $code)."
}

[ $# -ge 1 ] || usage

ACTION="$1"

case "$ACTION" in
    start)
        [ $# -eq 2 ] || [ $# -eq 3 ] || usage
        validate_mode "$2"
        validate_token "${3:-}"
        start "$2" "${3:-}"
        ;;
    status)
        [ $# -eq 1 ] || usage
        status
        ;;
    run)
        [ $# -eq 2 ] || [ $# -eq 3 ] || usage
        validate_mode "$2"
        validate_token "${3:-}"
        run "$2" "${3:-}"
        ;;
    *)
        usage
        ;;
esac
