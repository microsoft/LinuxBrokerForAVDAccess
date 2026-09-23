#!/bin/bash
set -euo pipefail

mode="${1:-full}"
if [[ "$mode" != full && "$mode" != platform && "$mode" != legacy-enrollment && "$mode" != ready ]]; then
    echo 'Usage: check-broker-host-prerequisites.sh [platform|full|legacy-enrollment|ready]' >&2
    exit 1
fi

for directory in /usr /usr/local /usr/local/bin; do
    if [[ ! -e "$directory" && ! -L "$directory" ]]; then
        continue
    fi
    if [[ -L "$directory" || ! -d "$directory" || "$(stat -c %u "$directory")" != 0 ]]; then
        echo "$directory must be a root-owned, nonlinked directory before installing privileged broker helpers." >&2
        exit 1
    fi
    directory_mode=$(stat -c %a "$directory")
    if (( (8#$directory_mode & 022) != 0 )); then
        echo "$directory must not be group/world-writable. Repair its access policy explicitly; deployment will not change unrelated directory permissions." >&2
        exit 1
    fi
done

filesystem=$(stat -fc %T /sys/fs/cgroup)
if [[ "$filesystem" != cgroup2fs ]]; then
    freezer_root='' systemd_root=''
    while IFS= read -r record; do
        read -r -a fields <<< "$record"
        separator=0
        for ((index=6; index<${#fields[@]}; index++)); do
            if [[ "${fields[$index]}" == - ]]; then separator=$index; break; fi
        done
        if (( separator < 6 || separator + 3 >= ${#fields[@]} )); then
            echo 'Kernel mount inventory is malformed.' >&2
            exit 1
        fi
        [[ "${fields[$((separator+1))]}" == cgroup ]] || continue
        options=",${fields[$((separator+3))]},"
        if [[ "$options" != *,freezer,* && "$options" != *,name=systemd,* ]]; then continue; fi
        if [[ "$options" != *,rw,* || "$options" == *,ro,* ]]; then
            echo 'Legacy gate controller mounts must be writable; read-only controllers cannot safely gate cleanup.' >&2
            exit 1
        fi
        target="${fields[4]}"
        if [[ "${fields[3]}" != / || "$target" != /* || "$target" == / || "$target" == *\\* ||
              "$target" == *'/../'* || "$target" == */.. ]]; then
            echo 'The legacy gate requires complete, unambiguous controller mount paths.' >&2
            exit 1
        fi
        if [[ "$options" == *,freezer,* ]]; then
            [[ -z "$freezer_root" ]] || { echo 'Multiple freezer mounts are ambiguous.' >&2; exit 1; }
            IFS=, read -r -a controller_options <<< "${fields[$((separator+3))]}"
            for option in "${controller_options[@]}"; do
                case "$option" in rw|ro|relatime|seclabel|xattr|noprefix|clone_children|freezer) ;;
                    *) echo 'The legacy freezer must not share resource controllers.' >&2; exit 1 ;;
                esac
            done
            freezer_root="$target"
        fi
        if [[ "$options" == *,name=systemd,* ]]; then
            [[ -z "$systemd_root" ]] || { echo 'Multiple systemd controller mounts are ambiguous.' >&2; exit 1; }
            systemd_root="$target"
        fi
    done < /proc/self/mountinfo
    if [[ -z "$freezer_root" || -z "$systemd_root" || ! -f "$freezer_root/cgroup.procs" ||
          ! -f "$systemd_root/cgroup.procs" ]]; then
        echo 'Neither unified cgroup v2 nor separate complete v1 freezer/systemd controllers are available. No weaker cleanup gate is permitted.' >&2
        exit 1
    fi
    for controller in "$freezer_root" "$systemd_root"; do
        controller_mode=$(stat -c %a "$controller")
        if [[ -L "$controller" || "$(stat -fc %T "$controller")" != cgroupfs ||
              "$(stat -c %u "$controller")" != 0 ]] || (( (8#$controller_mode & 022) != 0 )); then
            echo 'Legacy cgroup controller mounts must be visible and root-controlled.' >&2
            exit 1
        fi
    done
    if [[ "$mode" == platform || "$mode" == legacy-enrollment ]]; then
        echo 'Legacy v1 freezer platform is available. Startup enrollment and a verified drained host are required before activation.'
        exit 0
    fi
    if [[ ! -x /usr/local/bin/manage-lease.sh || ! -x /usr/local/libexec/linuxbroker/python3 ]]; then
        echo 'Legacy gate is not enrolled. Use explicit drained-host enrollment; do not adopt running PID trees.' >&2
        exit 1
    fi
    /usr/local/bin/manage-lease.sh gate-status
    exit $?
fi
version_output=$(systemctl --version)
if [[ ! "$version_output" =~ ^systemd[[:space:]]+([0-9]+) ]] || (( BASH_REMATCH[1] < 246 )); then
    echo 'The unified-cgroup gate requires systemd >=246; no unverified backend fallback is permitted.' >&2
    exit 1
fi
[[ -f /sys/fs/cgroup/cgroup.controllers ]] || { echo 'Unified cgroup v2 controller metadata is missing.' >&2; exit 1; }

if [[ "$mode" == platform ]]; then
    echo 'Broker platform prerequisite checks passed; XRDP control groups must also pass after package installation.'
    exit 0
fi

for unit in xrdp.service xrdp-sesman.service; do
    properties=$(systemctl show "$unit" --property=LoadState --property=ActiveState --property=ControlGroup --property=FreezerState --no-pager)
    load_state='' active_state='' control_group='' freezer_state=''
    while IFS='=' read -r key value; do
        case "$key" in
            LoadState) load_state="$value" ;;
            ActiveState) active_state="$value" ;;
            ControlGroup) control_group="$value" ;;
            FreezerState) freezer_state="$value" ;;
        esac
    done <<< "$properties"
    if [[ "$load_state" != loaded || "$active_state" != active || "$control_group" != /* ||
          "$control_group" == / || "$control_group" == *'/../'* || "$control_group" == *'/./'* ||
          "$control_group" == */.. || "$control_group" == */. ]]; then
        echo "$unit must be loaded and active with its own valid control group before broker activation." >&2
        exit 1
    fi
    freeze_file="/sys/fs/cgroup$control_group/cgroup.freeze"
    events_file="/sys/fs/cgroup$control_group/cgroup.events"
    if [[ ! -f "$freeze_file" || ! -f "$events_file" ]]; then
        echo "$unit does not expose the required cgroup v2 freezer files." >&2
        exit 1
    fi
    freeze_value=$(cat "$freeze_file")
    frozen_event=''
    while read -r event value; do
        if [[ "$event" == frozen ]]; then frozen_event="$value"; fi
    done < "$events_file"
    case "$freezer_state:$freeze_value:$frozen_event" in
        running:0:0) ;;
        frozen:1:1)
            if [[ "$mode" == ready ]]; then
                echo "$unit requires guarded thaw recovery before checkout can resume. No service state was changed." >&2
                exit 1
            fi
            echo "$unit is already frozen. Preflight leaves it unchanged; complete guarded gateClosed recovery before activation." >&2
            ;;
        *)
            echo "$unit freezer state is unsupported, transitioning, or inconsistent. No service state was changed." >&2
            exit 1
            ;;
    esac
done

if [[ "$mode" == ready ]]; then
    /usr/local/bin/manage-lease.sh gate-status
fi
echo 'Broker XRDP freezer prerequisites passed. This read-only check did not freeze, thaw, start, or stop any service.'
