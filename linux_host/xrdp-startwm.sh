#!/bin/bash
#
# Usage: xrdp-startwm.sh --install
#        xrdp-startwm.sh
#
# The script xrdp starts every desktop session with. It starts the desktop that
# /etc/linuxbroker/desktop.conf names, which the host bootstrap writes: the distribution's own
# script cannot start Ubuntu's session on Xorg, or choose between desktops installed side by
# side. Anything this script does not handle, including a host without desktop.conf, runs the
# distribution's script exactly as before.
#
# --install, as root, points DefaultWindowManager in /etc/xrdp/sesman.ini at this script. It
# records the script it replaces in /etc/linuxbroker/xrdp-startwm.conf, keeps the original
# file as sesman.ini.linuxbroker-orig, and installs a polkit rule so broker users are not asked
# for an administrator's password inside an xrdp session. It is idempotent: the host migration
# runs it, and patch-host.sh runs it after every patch run in case an update replaced
# sesman.ini. It exits 3 when xrdp is not installed, and 1 on any other failure.

# The Linux Broker host agent version. Every script in linux_host/ declares the same value
# and the heartbeat reports it; bump them together with HOST_AGENT_VERSION in api/config.py.
LINUXBROKER_AGENT_VERSION="1.1.0"

LAUNCHER_PATH="/usr/local/bin/xrdp-startwm.sh"
SESMAN_INI="/etc/xrdp/sesman.ini"
SESMAN_BACKUP="/etc/xrdp/sesman.ini.linuxbroker-orig"
SESMAN_SERVICE="xrdp-sesman.service"
SETTINGS_DIRECTORY="/etc/linuxbroker"
STATE_FILE="$SETTINGS_DIRECTORY/xrdp-startwm.conf"
DESKTOP_FILE="$SETTINGS_DIRECTORY/desktop.conf"
POLKIT_RULES_DIRECTORY="/etc/polkit-1/rules.d"
POLKIT_RULE_FILE="$POLKIT_RULES_DIRECTORY/45-linuxbroker-xrdp.rules"
UBUNTU_SESSION_FILE="/usr/share/gnome-session/sessions/ubuntu.session"

# Where a relative DefaultWindowManager lives: /etc/xrdp upstream, /usr/libexec/xrdp in the
# Fedora and EPEL packages.
WM_DIRECTORIES=(/etc/xrdp /usr/libexec/xrdp)
# The distribution scripts, tried in this order when the recorded one is unusable.
FALLBACK_WMS=(/usr/libexec/xrdp/startwm-bash.sh /usr/libexec/xrdp/startwm.sh /etc/xrdp/startwm.sh)

SESMAN_TMP=""

usage() {
    echo "Usage: $0 --install" >&2
    exit 2
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

restore_context() {
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$1" >/dev/null 2>&1 || true
    fi
}

is_launcher() {
    local target

    [ "$1" = "$LAUNCHER_PATH" ] && return 0
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    target=$(readlink -f -- "$1" 2>/dev/null) || return 1
    [ -n "$target" ] && [ "$target" = "$(readlink -f -- "$LAUNCHER_PATH" 2>/dev/null)" ]
}

# A session script that can be run: a plain absolute path to an executable file other than
# this script.
usable_wm() {
    [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    if [ ! -f "$1" ] || [ ! -x "$1" ]; then
        return 1
    fi
    ! is_launcher "$1"
}

# Prints the script a DefaultWindowManager value names, when it is usable.
resolve_wm() {
    local directory

    case "$1" in
        "")
            return 1
            ;;
        /*)
            usable_wm "$1" && printf '%s\n' "$1"
            ;;
        *)
            for directory in "${WM_DIRECTORIES[@]}"; do
                if usable_wm "$directory/$1"; then
                    printf '%s\n' "$directory/$1"
                    return 0
                fi
            done
            return 1
            ;;
    esac
}

first_fallback_wm() {
    local candidate

    for candidate in "${FALLBACK_WMS[@]}"; do
        if usable_wm "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# The distribution script --install recorded, when it is still usable. The file is read,
# never sourced.
recorded_wm() {
    local value

    [ -r "$STATE_FILE" ] || return 1
    value=$(sed -n 's/^ORIGINAL_WM=//p' "$STATE_FILE" 2>/dev/null | tail -n 1)
    usable_wm "$value" && printf '%s\n' "$value"
}

# Prints "=" and the value of DefaultWindowManager in [Globals], or nothing when it is not
# set. As in xrdp, names are case-insensitive, values are trimmed and the last one wins.
read_default_wm() {
    awk '
        { sub(/\r$/, "") }
        /^[[:space:]]*[;#]/ { next }
        /^[[:space:]]*\[/ {
            section = $0
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\].*$/, "", section)
            in_globals = (tolower(section) == "globals")
            next
        }
        in_globals && index($0, "=") > 0 {
            key = substr($0, 1, index($0, "=") - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (tolower(key) == "defaultwindowmanager") {
                value = substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                found = 1
            }
        }
        END { if (found) print "=" value }
    ' "$1"
}

# Prints sesman.ini with DefaultWindowManager in [Globals] set to this script, adding the key
# after the section header when add_key is 1. Fails when there is no [Globals] section.
rewrite_sesman() {
    awk -v launcher="$LAUNCHER_PATH" -v add_key="$2" '
        {
            line = $0
            sub(/\r$/, "", line)
        }
        line ~ /^[[:space:]]*[;#]/ { print; next }
        line ~ /^[[:space:]]*\[/ {
            section = line
            sub(/^[[:space:]]*\[/, "", section)
            sub(/\].*$/, "", section)
            in_globals = (tolower(section) == "globals")
            print
            if (in_globals) {
                seen = 1
                if (add_key == "1") print "DefaultWindowManager=" launcher
            }
            next
        }
        in_globals && index(line, "=") > 0 {
            key = substr(line, 1, index(line, "=") - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (tolower(key) == "defaultwindowmanager") {
                print "DefaultWindowManager=" launcher
                next
            }
        }
        { print }
        END { if (!seen) exit 1 }
    ' "$1"
}

# Writes content to a file only when it differs, through a temporary file in the same
# directory so a reader never sees half of it.
write_managed_file() {
    local path="$1" content="$2" tmp

    if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
        return 0
    fi
    tmp=$(mktemp "$path.XXXXXX") || return 1
    if ! printf '%s\n' "$content" > "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    restore_context "$path"
}

write_state() {
    if ! mkdir -p "$SETTINGS_DIRECTORY" || ! chmod 755 "$SETTINGS_DIRECTORY"; then
        return 1
    fi
    write_managed_file "$STATE_FILE" "# Managed by xrdp-startwm.sh: the session script xrdp ran before Linux Broker's.
ORIGINAL_WM=$1"
}

polkit_rule() {
    cat <<'RULE'
// Managed by xrdp-startwm.sh (Linux Broker). Manual edits are overwritten.
//
// polkit asks for an administrator's password when a remote session creates a color profile
// for its display or refreshes the package lists, and broker users never have one. Both are
// allowed for them (the tsusers group) instead.
polkit.addRule(function(action, subject) {
    var allowed = [
        "org.freedesktop.color-manager.create-device",
        "org.freedesktop.color-manager.create-profile",
        "org.freedesktop.color-manager.delete-device",
        "org.freedesktop.color-manager.delete-profile",
        "org.freedesktop.color-manager.modify-device",
        "org.freedesktop.color-manager.modify-profile",
        "org.freedesktop.packagekit.system-sources-refresh"
    ];
    if (allowed.indexOf(action.id) >= 0 && subject.isInGroup("tsusers")) {
        return polkit.Result.YES;
    }
});
RULE
}

install_polkit_rule() {
    if [ ! -d "$POLKIT_RULES_DIRECTORY" ]; then
        echo "polkit is not installed, so no polkit rule is needed."
        return 0
    fi
    # polkitd notices the new file by itself.
    write_managed_file "$POLKIT_RULE_FILE" "$(polkit_rule)"
}

# xrdp-sesman reloads sesman.ini on SIGHUP without touching running sessions, which a restart
# can end. xrdp 0.10 also reads it again for every new session.
reload_sesman() {
    local pid

    command -v systemctl >/dev/null 2>&1 || return 0
    pid=$(systemctl show --property MainPID --value "$SESMAN_SERVICE" 2>/dev/null)
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ]; then
        if kill -HUP "$pid" 2>/dev/null; then
            echo "Asked xrdp-sesman to reload $SESMAN_INI."
        else
            echo "WARNING: Could not signal xrdp-sesman. It uses the new $SESMAN_INI once restarted."
        fi
    fi
}

install_launcher() {
    local current configured="startwm.sh" add_key=1 original="" backup_value

    set -u
    umask 022
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    trap '[ -z "$SESMAN_TMP" ] || rm -f "$SESMAN_TMP"' EXIT

    [ "$(id -u)" -eq 0 ] || fail "--install must run as root."
    [ -x "$LAUNCHER_PATH" ] || fail "$LAUNCHER_PATH is missing or not executable."
    if [ ! -f "$SESMAN_INI" ]; then
        echo "xrdp is not installed: $SESMAN_INI does not exist."
        exit 3
    fi

    current=$(read_default_wm "$SESMAN_INI") || fail "Could not read $SESMAN_INI."
    if [ -n "$current" ]; then
        add_key=0
        configured="${current#=}"
        # xrdp's own default when the value is empty.
        [ -n "$configured" ] || configured="startwm.sh"
    fi

    if is_launcher "$configured"; then
        # Already installed: only make sure the script it falls back to is still there.
        if ! original=$(recorded_wm) && [ -f "$SESMAN_BACKUP" ]; then
            backup_value=$(read_default_wm "$SESMAN_BACKUP") || backup_value=""
            backup_value="${backup_value#=}"
            original=$(resolve_wm "${backup_value:-startwm.sh}") || original=""
        fi
        [ -n "$original" ] || original=$(first_fallback_wm) || fail "No xrdp session script was found to fall back to."
        write_state "$original" || fail "Could not write $STATE_FILE."
        echo "xrdp already starts sessions through $LAUNCHER_PATH, which falls back to $original."
    else
        original=$(resolve_wm "$configured") || original=$(first_fallback_wm) || fail "No xrdp session script was found to fall back to."
        SESMAN_TMP=$(mktemp "$SESMAN_INI.linuxbroker.XXXXXX") || fail "Could not update $SESMAN_INI."
        rewrite_sesman "$SESMAN_INI" "$add_key" > "$SESMAN_TMP" || fail "$SESMAN_INI has no [Globals] section."
        # The state first, so a session that starts in between already finds its script.
        write_state "$original" || fail "Could not write $STATE_FILE."
        if [ ! -e "$SESMAN_BACKUP" ]; then
            cp -p "$SESMAN_INI" "$SESMAN_BACKUP" || fail "Could not back up $SESMAN_INI."
        fi
        if ! chmod --reference="$SESMAN_INI" "$SESMAN_TMP" || ! chown --reference="$SESMAN_INI" "$SESMAN_TMP" \
            || ! mv -f "$SESMAN_TMP" "$SESMAN_INI"; then
            fail "Could not update $SESMAN_INI."
        fi
        SESMAN_TMP=""
        restore_context "$SESMAN_INI"
        echo "xrdp now starts sessions through $LAUNCHER_PATH, which falls back to $original."
        reload_sesman
    fi

    install_polkit_rule || fail "Could not write $POLKIT_RULE_FILE."
    exit 0
}

log_session() {
    if command -v logger >/dev/null 2>&1; then
        logger -t linuxbroker-startwm -- "$1" >/dev/null 2>&1 || true
    fi
}

# The desktop desktop.conf names, or nothing when it names none this script starts. The file
# is read, never sourced.
configured_desktop() {
    local value

    [ -r "$DESKTOP_FILE" ] || return 0
    value=$(sed -n 's/^[[:space:]]*DESKTOP[[:space:]]*=//p' "$DESKTOP_FILE" 2>/dev/null | tail -n 1)
    value=$(printf '%s' "$value" | tr -d "\"' \t\r" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        gnome|xfce|mate) printf '%s\n' "$value" ;;
        "") ;;
        *) log_session "Ignoring DESKTOP=$value in $DESKTOP_FILE: expected gnome, xfce or mate." ;;
    esac
}

# Starts the desktop through Debian's Xsession, after the same profiles xrdp's own script
# reads. Returns when the desktop is not installed.
start_debian_desktop() {
    local startup

    case "$1" in
        gnome)
            command -v gnome-session >/dev/null 2>&1 || return 1
            if [ -f "$UBUNTU_SESSION_FILE" ]; then
                # What GDM sets for "Ubuntu on Xorg": Ubuntu's session, theme and dock.
                export DESKTOP_SESSION=ubuntu XDG_SESSION_DESKTOP=ubuntu XDG_CURRENT_DESKTOP=ubuntu:GNOME GNOME_SHELL_SESSION_MODE=ubuntu
                startup="gnome-session --session=ubuntu"
            else
                export DESKTOP_SESSION=gnome XDG_SESSION_DESKTOP=gnome XDG_CURRENT_DESKTOP=GNOME
                startup="gnome-session"
            fi
            ;;
        *)
            return 1
            ;;
    esac

    # gnome-session starts the X11 flavor of its systemd units from this.
    export XDG_SESSION_TYPE=x11
    log_session "Starting $1 for $(id -un 2>/dev/null) with: $startup"
    # shellcheck disable=SC2016 # expanded by the inner shell
    exec /bin/sh -c 'linuxbroker_startup=$1
if test -r /etc/profile; then . /etc/profile; fi
if test -r "$HOME/.profile"; then . "$HOME/.profile"; fi
exec /etc/X11/Xsession "$linuxbroker_startup"' linuxbroker-startwm "$startup"
}

run_original() {
    local original

    original=$(recorded_wm) || original=$(first_fallback_wm) || original=""
    if [ -n "$original" ]; then
        exec "$original"
    fi

    log_session "No xrdp session script was found, so the X session is started directly."
    if [ -x /etc/X11/Xsession ]; then
        exec /etc/X11/Xsession
    fi
    if [ -x /etc/X11/xinit/Xsession ]; then
        exec /etc/X11/xinit/Xsession
    fi
    log_session "No X session script was found either, so the session cannot start."
    exit 1
}

start_session() {
    local desktop

    desktop=$(configured_desktop)
    if [ -n "$desktop" ] && [ -d /etc/X11/Xsession.d ] && [ -x /etc/X11/Xsession ]; then
        start_debian_desktop "$desktop"
        log_session "$desktop is not installed, so the distribution's session script is used."
    fi
    run_original
}

case "${1:-}" in
    --install)
        [ $# -eq 1 ] || usage
        install_launcher
        ;;
    *)
        start_session
        ;;
esac
