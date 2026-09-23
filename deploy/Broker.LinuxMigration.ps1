. "$PSScriptRoot\Broker.Deployment.Common.ps1"
. "$PSScriptRoot\Broker.IdleLease.ps1"

function Get-BrokerHostPrerequisiteScript {
    param([ValidateSet('platform', 'full', 'legacy-enrollment', 'ready')][string]$Mode = 'full')
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'custom_script_extensions\check-broker-host-prerequisites.sh'
    return "(`nset -- '$Mode'`n" + (Get-Content -LiteralPath $path -Raw).Replace("`r`n", "`n") + "`n)"
}

function Test-BrokerHostPrerequisites {
    param([AllowEmptyCollection()][array]$Hosts, [switch]$AllowDrainedLegacyEnrollment, [switch]$RequireReady)
    if ($AllowDrainedLegacyEnrollment -and $RequireReady) { throw 'Enrollment planning cannot be used as a ready-gate check.' }
    $mode = if ($RequireReady) { 'ready' } elseif ($AllowDrainedLegacyEnrollment) { 'legacy-enrollment' } else { 'full' }
    $script = Get-BrokerHostPrerequisiteScript -Mode $mode
    foreach ($hostRecord in $Hosts) {
        Invoke-BrokerVmScript -ResourceId $hostRecord.ResourceId -CommandId RunShellScript -Script $script `
            -Operation "Check systemd/cgroup/XRDP prerequisites without changing services on '$($hostRecord.Name)'"
    }
}

function Get-BrokerAgentQuiesceScript {
    return @'
test "$(id -u)" = 0
for unit in linuxbroker-release-session-watcher.service linuxbroker-release-session.timer linuxbroker-release-session.service; do
    if systemctl list-unit-files "$unit" --no-legend | grep -q "^$unit "; then
        systemctl disable --now "$unit"
    fi
done
if command -v crontab >/dev/null 2>&1; then
    cron_before=$(mktemp)
    cron_after=$(mktemp)
    if crontab -l > "$cron_before" 2>/dev/null; then
        grep -v -F '/usr/local/bin/release-session.sh' "$cron_before" > "$cron_after" || test "$?" = 1
        crontab "$cron_after"
    else
        test ! -s "$cron_before"
    fi
    rm -f -- "$cron_before" "$cron_after"
fi
# Only terminate PIDs whose argv contains an exact legacy agent path. Never touch XRDP/Xorg or user sessions.
for proc in /proc/[0-9]*/cmdline; do
    test -r "$proc" || continue
    if tr '\0' '\n' < "$proc" 2>/dev/null | grep -Fxq -e /usr/local/bin/release-session.sh -e /usr/local/bin/logind-session-watcher.sh; then
        pid=${proc#/proc/}; pid=${pid%/cmdline}
        test "$pid" != "$$"
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid"
            for attempt in 1 2 3 4 5; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "$pid" 2>/dev/null; then
                echo 'A legacy release agent did not stop. Keep the broker paused and resolve it before migrating.' >&2
                exit 1
            fi
        fi
    fi
done
'@
}

function Test-BrokerMigrationLease {
    param([AllowEmptyCollection()][array]$Rows, [string]$Hostname)
    if ($Rows.Count -gt 1) { throw "Host '$Hostname' has more than one migration lease." }
    if (-not $Rows.Count) { return $null }
    $lease = $Rows[0]
    Assert-BrokerLinuxIdentity -Username $lease.Username -Uid $lease.Uid
    $lease.LeaseId = Assert-BrokerGuid ([string]$lease.LeaseId) 'Migration LeaseId'
    if (($lease.LeaseGeneration -isnot [int] -and $lease.LeaseGeneration -isnot [long]) -or
        $lease.LeaseGeneration -lt 1 -or $lease.LeaseGeneration -gt 9007199254740991L) {
        throw "Host '$Hostname' has a lease generation outside the shared SQL/JSON range 1..9007199254740991; do not infer, truncate, or replace it."
    }
    return $lease
}

function Get-BrokerLinuxArtifactHashes {
    param([Parameter(Mandatory)][string]$SourceRoot)
    $paths = @(
        'custom_script_extensions/Configure-RHEL7-Host.sh',
        'custom_script_extensions/Configure-RHEL8-Host.sh',
        'custom_script_extensions/Configure-RHEL9-Host.sh',
        'custom_script_extensions/Configure-Ubuntu24_desktop-Host.sh',
        'custom_script_extensions/install-broker-python.py',
        'custom_script_extensions/check-broker-host-prerequisites.sh',
        'custom_script_extensions/configure-broker-xrdp-gate.py',
        'linux_host/create-user.sh',
        'linux_host/manage-lease.sh',
        'linux_host/broker-lease.py',
        'linux_host/broker-freezer.py',
        'linux_host/apply-host-settings.sh',
        'linux_host/session_release_buffer/xrdp-who-xorg.sh',
        'linux_host/session_release_buffer/logind-session-watcher.sh',
        'linux_host/session_release_buffer/release-session-common.sh',
        'linux_host/session_release_buffer/RHEL/release-session.sh',
        'linux_host/session_release_buffer/Ubuntu/release-session.sh'
    )
    $hashes = @{}
    foreach ($relative in $paths) {
        $path = Join-Path $SourceRoot $relative.Replace('/', '\')
        $content = (Get-Content -LiteralPath $path -Raw -Encoding utf8).Replace("`r`n", "`n")
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
        $hashes[$relative] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
    return $hashes
}

function Get-BrokerPythonRuntimeLock {
    param([string]$MirrorUri)
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'linux-python.lock.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($config.schemaVersion -ne 1 -or $config.version -notmatch '^3\.(?:9|[1-9][0-9])\.[0-9]+$' -or
        $config.sha256 -notmatch '^[a-f0-9]{64}$' -or $config.target -ne 'x86_64-unknown-linux-gnu' -or $config.minimumGlibc -ne '2.17') {
        throw 'The deployment-pinned private Linux Python runtime lock is invalid.'
    }
    if ($MirrorUri) { $config.uri = Assert-BrokerHttpsUrl $MirrorUri }
    else { $null = Assert-BrokerHttpsUrl $config.uri }
    return $config
}

function New-BrokerAgentInstallScript {
    param(
        [Parameter(Mandatory)][string]$ApiBaseUrl,
        [Parameter(Mandatory)][string]$ApiClientId,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$AdminUsername,
        [Parameter(Mandatory)][string]$SourceRoot,
        [hashtable]$Lease,
        [hashtable]$IdleEvidence,
        [switch]$EnrollDrainedLegacyHosts,
        [string]$PythonRuntimeUri,
        [int]$WatcherDebounceSeconds = 10,
        [int]$WatcherSettleSeconds = 2
    )
    if ($AdminUsername -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $AdminUsername -in @('root', 'nobody')) {
        throw 'Invalid broker SSH administrator username.'
    }
    $null = Assert-BrokerHttpsUrl $ApiBaseUrl -Api
    $null = Assert-BrokerGuid $ApiClientId 'API client ID'
    if ($Hostname -notmatch '^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$') { throw 'Invalid registered ARM hostname.' }
    $hostRoot = Join-Path $SourceRoot 'linux_host'
    $runtimeConfig = Get-BrokerPythonRuntimeLock -MirrorUri $PythonRuntimeUri
    $runtimeConfigBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($runtimeConfig | ConvertTo-Json -Compress)))
    $runtimeInstallerPath = Join-Path $SourceRoot 'custom_script_extensions\install-broker-python.py'
    $runtimeInstallerBytes = [Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $runtimeInstallerPath -Raw).Replace("`r`n", "`n"))
    $runtimeInstallerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($runtimeInstallerBytes)).ToLowerInvariant()
    $files = @(Get-ChildItem -LiteralPath $hostRoot -Filter '*.sh' -File) +
        @(Get-Item -LiteralPath (Join-Path $hostRoot 'broker-lease.py'), (Join-Path $hostRoot 'broker-freezer.py')) +
        @(Get-Item -LiteralPath (Join-Path $SourceRoot 'custom_script_extensions\configure-broker-xrdp-gate.py')) +
        @(Get-ChildItem -LiteralPath (Join-Path $hostRoot 'session_release_buffer') -Filter '*.sh' -File)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $installLines = [Collections.Generic.List[string]]::new()
    function Convert-AgentContent {
        param([string]$Path)
        $content = (Get-Content -LiteralPath $Path -Raw).Replace("`r`n", "`n")
        $escapedUrl = $ApiBaseUrl.Replace('\', '\\').Replace('$', '\$').Replace('"', '\"').Replace('`', '\`')
        return $content.Replace('YOUR_LINUX_BROKER_API_CLIENT_ID', $ApiClientId).
            Replace('YOUR_LINUX_BROKER_API_BASE_URL', $escapedUrl).Replace('YOUR_LINUX_BROKER_API_URL', $escapedUrl)
    }
    function Get-AgentInstallLine {
        param([string]$Path, [string]$Name)
        $bytes = [Text.Encoding]::UTF8.GetBytes((Convert-AgentContent $Path))
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        return "install_script '$Name' '$hash' '$([Convert]::ToBase64String($bytes))'"
    }
    foreach ($file in $files) {
        if ($file.Name -cnotmatch '^[a-z][a-z0-9-]*\.(sh|py)$' -or -not $names.Add($file.Name)) {
            throw 'Agent bundle has an unsupported or duplicate helper filename.'
        }
        $installLines.Add((Get-AgentInstallLine -Path $file.FullName -Name $file.Name))
    }
    foreach ($required in @('create-user.sh', 'manage-lease.sh', 'broker-lease.py', 'broker-freezer.py', 'apply-host-settings.sh',
            'xrdp-who-xorg.sh', 'logind-session-watcher.sh', 'release-session-common.sh')) {
        if (-not $names.Contains($required)) { throw "The local agent bundle is missing '$required'." }
    }
    $rhelLine = Get-AgentInstallLine -Path (Join-Path $hostRoot 'session_release_buffer\RHEL\release-session.sh') -Name 'release-session.sh'
    $ubuntuLine = Get-AgentInstallLine -Path (Join-Path $hostRoot 'session_release_buffer\Ubuntu\release-session.sh') -Name 'release-session.sh'
    $markerCommand = if ($Lease) {
        $Lease = Test-BrokerMigrationLease -Rows @($Lease) -Hostname 'migration target'
        $leaseId = Assert-BrokerGuid ([string]$Lease.LeaseId) 'LeaseId'
        "/usr/local/bin/manage-lease.sh migrate '$($Lease.Username)' '$($Lease.Uid)' '$leaseId' '$($Lease.LeaseGeneration)'"
    } else {
        if (-not $IdleEvidence -or $IdleEvidence.kind -notin @('absent', 'cleaned')) {
            throw 'An idle host requires inspected marker metadata and trusted SQL identity/fence evidence before installation.'
        }
        Get-BrokerIdleLeaseScript -Evidence $IdleEvidence
    }
    $username = if ($Lease) { $Lease.Username } else { '' }
    $uid = if ($Lease) { [string]$Lease.Uid } else { '' }
    $gateEvidence = if ($Lease) { @{ kind = 'active' } } else { $IdleEvidence }
    $gateEvidenceBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($gateEvidence | ConvertTo-Json -Compress)))
    $gateEnrollmentOption = if ($EnrollDrainedLegacyHosts -and -not $Lease) { '--enroll-drained' } else { '' }
    $prerequisiteMode = if ($EnrollDrainedLegacyHosts) { 'legacy-enrollment' } else { 'full' }
    $script = @'
__HOST_PREREQUISITES__
__QUIESCE__
umask 077
temporary_files=()
cleanup_deployment_files() {
    local file
    for file in "${temporary_files[@]-}"; do
        if test -n "$file"; then rm -f -- "$file"; fi
    done
}
trap cleanup_deployment_files EXIT
admin_user=__ADMIN__
expected_username=__USERNAME__
expected_uid=__UID__
expected_hostname=__HOSTNAME__
if test "$(hostname | tr '[:upper:]' '[:lower:]')" != "$expected_hostname"; then
    echo 'Guest hostname does not match its trusted ARM registration. Resolve the drift before activation.' >&2
    exit 1
fi
state_directory=/var/lib/linuxbroker-release-session
lease_directory="$state_directory/leases"
ensure_command() {
    local binary="$1" package="$2"
    if command -v "$binary" >/dev/null 2>&1; then return 0; fi
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y "$package"
    elif command -v yum >/dev/null 2>&1; then yum install -y "$package"
    else echo "Missing required command: $binary" >&2; return 1
    fi
    command -v "$binary" >/dev/null
}
ensure_command python3 python3
ensure_command jq jq
ensure_command flock util-linux
ensure_command findmnt util-linux
ensure_command sha256sum coreutils
if command -v apt-get >/dev/null 2>&1; then
    iproute_package=iproute2
    process_package=procps
    account_package=passwd
    getent_package=libc-bin
    nfs_package=nfs-common
else
    iproute_package=iproute
    process_package=procps-ng
    account_package=shadow-utils
    getent_package=glibc-common
    nfs_package=nfs-utils
fi
ensure_command ss "$iproute_package"
for binary in ps pgrep pkill; do ensure_command "$binary" "$process_package"; done
for binary in useradd usermod userdel groupadd chpasswd; do ensure_command "$binary" "$account_package"; done
ensure_command getent "$getent_package"
ensure_command mount.nfs "$nfs_package"
ensure_command mount util-linux
ensure_command umount util-linux
python3 -c 'import sys; assert sys.version_info >= (3, 6), "The runtime installer requires the supported distro Python 3.6+."'
runtime_installer=$(mktemp /usr/local/bin/.broker-python-installer.XXXXXX)
temporary_files+=("$runtime_installer")
printf '%s' '__RUNTIME_INSTALLER__' | base64 --decode > "$runtime_installer"
printf '%s  %s\n' '__RUNTIME_INSTALLER_HASH__' "$runtime_installer" | sha256sum --check --status
python3 "$runtime_installer" --config-base64 '__RUNTIME_CONFIG__'
broker_python=/usr/local/libexec/linuxbroker/python3
"$broker_python" -I -c 'import sys; assert sys.version_info >= (3, 9), "The deployment-pinned broker interpreter is required."'
rm -f -- "$runtime_installer"
for path in /usr/local/bin "$state_directory" "$lease_directory"; do
    if test -L "$path"; then echo 'Refusing linked broker paths.' >&2; exit 1; fi
done
install -d -o root -g root -m 0700 "$state_directory" "$lease_directory"
shopt -s nullglob dotglob
for temporary_marker in "$state_directory"/.lease-*; do
    echo 'An interrupted root-marker write needs explicit operator review.' >&2
    exit 1
done
for marker in "$lease_directory"/*.lease; do
    if test -z "$expected_username" || test "$marker" != "$lease_directory/$expected_username.lease" ||
       test -L "$marker" || test ! -f "$marker" || test "$(stat -c %u "$marker")" != 0; then
        echo 'Unknown, stale, or untrusted lease marker. Keep this host quarantined; review ownership instead of deleting or skipping it.' >&2
        exit 1
    fi
    marker_mode=$(stat -c %a "$marker")
    if (( (8#$marker_mode & 077) != 0 )); then
        echo 'A legacy lease marker is not root-private. Review it before migration.' >&2
        exit 1
    fi
done
mount_targets=$(findmnt -rn -o TARGET)
while IFS= read -r target; do
    case "$target" in
        /home/*)
            if test -z "$expected_username" || test "$target" != "/home/$expected_username"; then
                echo 'Unresolved mounted profile on host. No ownership or mount changes were made.' >&2
                exit 1
            fi
            ;;
    esac
done <<< "$mount_targets"
sessions=$(loginctl list-sessions --no-legend --no-pager)
while read -r session_id session_uid session_user remainder; do
    test -n "$session_id" || continue
    [[ "$session_uid" =~ ^[0-9]+$ ]] || { echo 'Unrecognized logind inventory.' >&2; exit 1; }
    if test "$session_uid" -ge 2000 && test "$session_user" != "$admin_user"; then
        if test "$session_user" != "$expected_username" || test "$session_uid" != "$expected_uid"; then
            echo 'A live session has no matching reviewed SQL lease. Keep the host quarantined.' >&2
            exit 1
        fi
    fi
done <<< "$sessions"
id "$admin_user" >/dev/null
install_script() {
    local name="$1" digest="$2" payload="$3" temporary destination
    [[ "$name" =~ ^[a-z][a-z0-9-]*\.(sh|py)$ ]] || return 1
    destination="/usr/local/bin/$name"
    test ! -L "$destination" || return 1
    temporary=$(mktemp /usr/local/bin/.broker-agent.XXXXXX)
    temporary_files+=("$temporary")
    printf '%s' "$payload" | base64 --decode > "$temporary"
    printf '%s  %s\n' "$digest" "$temporary" | sha256sum --check --status
    if [[ "$name" == *.py ]]; then
        "$broker_python" -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$temporary"
    else
        bash -n "$temporary"
    fi
    install -o root -g root -m 0755 "$temporary" "$destination"
    rm -f -- "$temporary"
}
__HELPERS__
test -r /etc/os-release
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:debian*) __UBUNTU__ ;;
    rhel:*|almalinux:*|centos:*|rocky:*|*:rhel*|*:fedora*) __RHEL__ ;;
    *) echo 'Unsupported Linux distribution; no agent was activated.' >&2; exit 1 ;;
esac
__MARKER_MIGRATION__
"$broker_python" -I /usr/local/bin/configure-broker-xrdp-gate.py __GATE_ENROLLMENT__ --admin-username "$admin_user" --idle-evidence-base64 '__GATE_EVIDENCE__'
sudoers_tmp=$(mktemp /etc/sudoers.d/.linuxbroker.XXXXXX)
temporary_files+=("$sudoers_tmp")
printf '%s ALL=(root) NOPASSWD: /usr/local/bin/create-user.sh *, /usr/local/bin/manage-lease.sh cleanup *, /usr/local/bin/apply-host-settings.sh ""\n' "$admin_user" > "$sudoers_tmp"
chown root:root "$sudoers_tmp"
chmod 0440 "$sudoers_tmp"
visudo -c -f "$sudoers_tmp"
mv -f "$sudoers_tmp" /etc/sudoers.d/avdadmin
for file in /var/log/release-session.log "$state_directory/current_users.txt" "$state_directory/previous_users.txt" "$state_directory/disconnected_users.tsv"; do
    test ! -L "$file"
    touch "$file"
    chown root:root "$file"
    chmod 0600 "$file"
done
cat > /etc/systemd/system/linuxbroker-release-session.service <<'UNIT'
[Unit]
Description=Linux Broker Release Agent
After=network-online.target xrdp.service
Wants=network-online.target
[Service]
Type=oneshot
User=root
WorkingDirectory=/var/lib/linuxbroker-release-session
ExecStart=/usr/local/bin/release-session.sh --systemd-timer
StandardOutput=journal
StandardError=journal
UNIT
cat > /etc/systemd/system/linuxbroker-release-session.timer <<'UNIT'
[Unit]
Description=Run Linux Broker Release Agent every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true
Unit=linuxbroker-release-session.service
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/linuxbroker-release-session-watcher.service <<'UNIT'
[Unit]
Description=Linux Broker logind Session Watcher
After=network-online.target systemd-logind.service
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/linuxbroker-release-session
Environment=LINUXBROKER_LOGIND_WATCHER_DEBOUNCE_SECONDS=__DEBOUNCE__
Environment=LINUXBROKER_LOGIND_WATCHER_SETTLE_SECONDS=__SETTLE__
ExecStart=/usr/local/bin/logind-session-watcher.sh
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
UNIT
if test ! -f /etc/linuxbroker/host-settings.conf; then
    /usr/local/bin/apply-host-settings.sh --defaults
fi
systemctl daemon-reload
install -d -o root -g root -m 0755 /etc/linuxbroker
printf '1\n' > /etc/linuxbroker/authorization-contract.version
chown root:root /etc/linuxbroker/authorization-contract.version
chmod 0644 /etc/linuxbroker/authorization-contract.version
echo 'Compatible agent and guarded lease marker staged. Reconciliation remains stopped until secure API activation.'
'@
    return $script.Replace('__HOST_PREREQUISITES__', (Get-BrokerHostPrerequisiteScript -Mode $prerequisiteMode)).
        Replace('__QUIESCE__', (Get-BrokerAgentQuiesceScript)).
        Replace('__ADMIN__', (ConvertTo-BrokerBashLiteral $AdminUsername)).
        Replace('__USERNAME__', (ConvertTo-BrokerBashLiteral $username)).
        Replace('__UID__', (ConvertTo-BrokerBashLiteral $uid)).
        Replace('__GATE_ENROLLMENT__', $gateEnrollmentOption).
        Replace('__GATE_EVIDENCE__', $gateEvidenceBase64).
        Replace('__HOSTNAME__', (ConvertTo-BrokerBashLiteral $Hostname.ToLowerInvariant())).
        Replace('__RUNTIME_INSTALLER__', [Convert]::ToBase64String($runtimeInstallerBytes)).
        Replace('__RUNTIME_INSTALLER_HASH__', $runtimeInstallerHash).
        Replace('__RUNTIME_CONFIG__', $runtimeConfigBase64).
        Replace('__HELPERS__', ($installLines -join "`n")).
        Replace('__UBUNTU__', $ubuntuLine).Replace('__RHEL__', $rhelLine).
        Replace('__MARKER_MIGRATION__', $markerCommand).
        Replace('__DEBOUNCE__', [string]$WatcherDebounceSeconds).Replace('__SETTLE__', [string]$WatcherSettleSeconds)
}

function Get-BrokerAgentActivationScript {
    return (Get-BrokerHostPrerequisiteScript -Mode ready) + "`n" + @'
test "$(id -u)" = 0
test "$(cat /etc/linuxbroker/authorization-contract.version)" = 1
test "$(stat -c %u /usr/local/bin/manage-lease.sh)" = 0
systemctl daemon-reload
systemctl start linuxbroker-release-session.service
systemctl enable --now linuxbroker-release-session.timer
systemctl enable --now linuxbroker-release-session-watcher.service
systemctl is-active --quiet linuxbroker-release-session.timer
systemctl is-active --quiet linuxbroker-release-session-watcher.service
'@
}
