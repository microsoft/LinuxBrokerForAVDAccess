#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

# Answers the IMDS token request, records every other call, keeps a copy of the posted
# heartbeat, and replies with FAKE_HTTP_STATUS.
install_heartbeat_curl_shim() {
    cat > /usr/bin/curl <<'SHIM'
#!/bin/bash
body_file=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  if [[ "$arg" == *"metadata/identity"* ]]; then
    printf '{"access_token":"token"}'
    exit 0
  fi
  if [ "$arg" = "--data-binary" ]; then
    j=$((i+1)); body_file="${!j#@}"
  fi
done
echo "$*" >> "${FAKE_CURL_CALLS:-/dev/null}"
if [ -n "$body_file" ] && [ -n "${FAKE_HEARTBEAT_BODY:-}" ]; then
  cp "$body_file" "$FAKE_HEARTBEAT_BODY"
fi
printf '%s' "${FAKE_HTTP_STATUS:-200}"
SHIM
    chmod +x /usr/bin/curl
}

assert_json() {
    local json="$1"
    local filter="$2"
    local label="$3"

    printf '%s' "$json" | jq -e "$filter" >/dev/null || fail "$label: expected $filter in $json"
}

post_count() {
    grep -c "/heartbeat" "$FAKE_CURL_CALLS" 2>/dev/null || true
}

heartbeat_for_script() {
    local script="$1"
    local label="$2"
    local bin="$WORK_DIR/bin-$label"
    local payload
    local session
    local xorg_pid
    local started

    reset_work
    install_basic_shims
    install_heartbeat_curl_shim
    export FAKE_CURL_CALLS="$WORK_DIR/curl-$label.log"
    export FAKE_HEARTBEAT_BODY="$WORK_DIR/heartbeat-$label.json"
    : > "$FAKE_CURL_CALLS"

    # shellcheck source=/dev/null
    . "$script"
    STATE_DIRECTORY="$WORK_DIR/state-$label"
    DISCONNECTED_USERS_FILE="$STATE_DIRECTORY/disconnected_users.tsv"
    LOG_FILE="$WORK_DIR/release-$label.log"
    LOCATION_PATH="$bin"
    hostname="testhost"
    SETTINGS_VERSION=7
    RUN_MODE="systemd-timer"
    mkdir -p "$STATE_DIRECTORY" "$bin"
    : > "$LOG_FILE"

    [ "$LINUXBROKER_AGENT_VERSION" = "1.1.0" ] || fail "$label declares agent version $LINUXBROKER_AGENT_VERSION"
    [[ " ${HEARTBEAT_SCRIPTS[*]} " == *" session-control.sh "* ]] || fail "$label does not report session-control.sh"
    [[ " ${HEARTBEAT_SCRIPTS[*]} " == *" patch-host.sh "* ]] || fail "$label does not report patch-host.sh"

    # One script is current and one predates the version constant.
    printf '#!/bin/bash\nLINUXBROKER_AGENT_VERSION="1.0.0"\n' > "$bin/release-session.sh"
    printf '#!/bin/bash\necho legacy\n' > "$bin/manage-lease.sh"
    assert_eq "$(collect_script_versions)" '{"release-session.sh":"1.0.0","manage-lease.sh":null}' "$label script versions"

    printf 'alice\t1790000000\n' > "$DISCONNECTED_USERS_FILE"
    session=$(session_json alice disconnected "2026-01-01 00:00" "")
    assert_json "$session" '.username == "alice" and .state == "disconnected" and .disconnectedSince == 1790000000' "$label session"
    assert_json "$session" '(.sessionStart | type) == "number" and .idleSeconds == null' "$label session times"

    payload=$(build_heartbeat "[$session]")
    assert_json "$payload" '.agentVersion == "1.1.0" and .settingsVersion == 7' "$label versions"
    assert_json "$payload" '.scriptVersions["manage-lease.sh"] == null and .scriptVersions["release-session.sh"] == "1.0.0"' "$label scripts"
    assert_json "$payload" '(.os.id | type) == "string" and (.kernel | type) == "string"' "$label os"
    assert_json "$payload" '.desktop == "none" and .xrdp.version == null and .xrdp.active == true' "$label desktop and xrdp"
    assert_json "$payload" '.nfs.mounts == 0 and .nfs.reachable == null' "$label nfs unknown"
    assert_json "$payload" '.memoryTotalMb > 0 and .cpuCount >= 1 and (.loadAverage | type) == "number"' "$label resources"
    assert_json "$payload" '.rootDiskFreePct >= 0 and .rootDiskFreePct <= 100 and .uptimeSeconds >= 0' "$label disk and uptime"
    assert_json "$payload" '.sessions | length == 1' "$label sessions"

    # A wedged X server cannot stall the run: the idle lookup gives up after the probe timeout
    # and the session is reported without an idle time.
    printf '#!/bin/bash\nsleep 30\n' > "$SHIM_DIR/xprintidle"
    chmod +x "$SHIM_DIR/xprintidle"
    bash -c 'sleep 30; true' fake-xorg :10 -auth .Xauthority &
    xorg_pid=$!
    SESSION_PROBE_TIMEOUT_SECONDS=1
    started=$SECONDS
    session=$(session_json alice active "" "$xorg_pid")
    [ $((SECONDS - started)) -lt 5 ] || fail "$label the idle lookup was not bounded"
    assert_json "$session" '.state == "active" and .idleSeconds == null' "$label hung idle lookup"
    kill "$xorg_pid" 2>/dev/null
    wait "$xorg_pid" 2>/dev/null
    rm -f "$SHIM_DIR/xprintidle"

    # With no home mounted, the NFS server remembered from an earlier mount is probed. Nothing
    # listens on 2049 here, and a name that is not a hostname is never used.
    printf '127.0.0.1\n' > "$STATE_DIRECTORY/nfs_server"
    assert_eq "$(check_nfs)" "0 false" "$label remembered NFS server"
    printf 'bad;name\n' > "$STATE_DIRECTORY/nfs_server"
    assert_eq "$(check_nfs)" "0 null" "$label invalid NFS server"

    export FAKE_HTTP_STATUS=200
    send_heartbeat "[$session]"
    assert_eq "$(post_count)" "1" "$label heartbeat posted"
    assert_file_contains "$FAKE_CURL_CALLS" "/hosts/testhost/heartbeat"
    assert_json "$(cat "$FAKE_HEARTBEAT_BODY")" '.sessions[0].username == "alice"' "$label posted body"
    [ -z "$(find "$STATE_DIRECTORY" -name 'heartbeat.*.json')" ] || fail "$label left a payload file behind"

    # Watcher runs never report.
    RUN_MODE="logind-watcher"
    send_heartbeat "[]"
    assert_eq "$(post_count)" "1" "$label watcher run should not post"
    RUN_MODE="systemd-timer"

    # An API without heartbeats is asked again only after the back-off.
    export FAKE_HTTP_STATUS=404
    send_heartbeat "[]"
    assert_eq "$(post_count)" "2" "$label 404 posted"
    assert_file_exists "$STATE_DIRECTORY/heartbeat_unsupported_until"
    assert_file_contains "$LOG_FILE" "Trying again in 15 minutes"
    send_heartbeat "[]"
    assert_eq "$(post_count)" "2" "$label backing off"

    # Other failures are retried every run but logged once.
    rm -f "$STATE_DIRECTORY/heartbeat_unsupported_until"
    export FAKE_HTTP_STATUS=500
    send_heartbeat "[]"
    send_heartbeat "[]"
    assert_eq "$(post_count)" "4" "$label retried after a failure"
    assert_eq "$(grep -c 'Heartbeat failed (HTTP 500)' "$LOG_FILE")" "1" "$label failure logged once"
    export FAKE_HTTP_STATUS=200
    send_heartbeat "[]"
    assert_not_exists "$STATE_DIRECTORY/heartbeat_failed"
    assert_file_contains "$LOG_FILE" "accepting heartbeats again"
}

heartbeat_for_script "$ROOT_DIR/linux_host/session_release_buffer/release-session.sh" agent
