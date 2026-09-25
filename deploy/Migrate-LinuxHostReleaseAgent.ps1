[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl,

    [Parameter(Mandatory = $false)]
    [string]$ApiClientId,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$ScriptSourceRoot = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main',

    [Parameter(Mandatory = $false)]
    [string[]]$LinuxHostNames,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 300)]
    [int]$WatcherDebounceSeconds = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60)]
    [int]$WatcherSettleSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
    $EnvironmentName = if (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) {
        $env:AZURE_ENV_NAME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:AZURE_ENVIRONMENT_NAME)) {
        $env:AZURE_ENVIRONMENT_NAME
    }
    else {
        ''
    }
}

function Get-AzdEnvValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        return ''
    }

    $value = azd env get-value $Key --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return ''
    }

    return ($value | Out-String).Trim()
}

function ConvertTo-BashSingleQuotedLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $replacement = "'" + '"' + "'" + '"' + "'"

    return "'" + ($Value -replace "'", $replacement) + "'"
}

function Invoke-RunCommandWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5
    )

    $lastError = ''

    # The script reaches az as @file. Passed inline, on Windows it goes through az.cmd, where
    # cmd.exe ends the command at the first newline: the host runs only the first line and the
    # call still succeeds. Bash also needs LF line endings, which a Windows checkout lacks.
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ('linuxbroker-migrate-{0}.sh' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($scriptFile, $Script.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $message = az vm run-command invoke `
                --resource-group $ResourceGroupName `
                --name $VmName `
                --command-id RunShellScript `
                --scripts "@$scriptFile" `
                --query 'value[0].message' `
                --output tsv `
                --only-show-errors 2>&1 | Out-String

            if ($LASTEXITCODE -eq 0) {
                return $message.Trim()
            }

            $lastError = $message.Trim()
            if ($attempt -ge $MaxAttempts) {
                break
            }

            $delaySeconds = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), 30)
            Write-Warning "Linux host migration failed on '$VmName' attempt $attempt of $MaxAttempts. Retrying in $([int]$delaySeconds) seconds."
            if (-not [string]::IsNullOrWhiteSpace($lastError)) {
                Write-Warning $lastError
            }

            Start-Sleep -Seconds ([int]$delaySeconds)
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($lastError)) {
        throw "Linux host migration failed on '$VmName'."
    }

    throw "Linux host migration failed on '$VmName'. Last error: $lastError"
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Get-AzdEnvValue -Key 'resourceGroupName'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = Get-AzdEnvValue -Key 'AZURE_SUBSCRIPTION_ID'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $ApiBaseUrl = Get-AzdEnvValue -Key 'apiUrl'
}

if ([string]::IsNullOrWhiteSpace($ApiClientId)) {
    $ApiClientId = Get-AzdEnvValue -Key 'apiClientId'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ApiBaseUrl) -or [string]::IsNullOrWhiteSpace($ApiClientId)) {
    throw 'Linux host migration inputs could not be fully resolved from parameters or azd environment values.'
}

$ScriptSourceRoot = $ScriptSourceRoot.TrimEnd('/')

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId | Out-Null
}

$linuxHosts = az vm list --resource-group $ResourceGroupName --show-details --output json | ConvertFrom-Json |
    Where-Object { $_.tags.'broker-role' -eq 'linux-host' }

if (-not $linuxHosts) {
    Write-Host "No Linux host VMs found in resource group '$ResourceGroupName'."
    exit 0
}

if ($LinuxHostNames -and $LinuxHostNames.Count -gt 0) {
    $requestedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $LinuxHostNames) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$requestedNames.Add($name)
        }
    }

    $filteredHosts = @($linuxHosts | Where-Object { $requestedNames.Contains($_.name) })
    foreach ($name in $requestedNames) {
        if (-not ($filteredHosts | Where-Object { $_.name -eq $name })) {
            Write-Warning "Requested Linux host '$name' was not found in resource group '$ResourceGroupName'."
        }
    }

    $linuxHosts = $filteredHosts
}

if (-not $linuxHosts) {
    Write-Host 'No Linux hosts matched the requested migration scope.'
    exit 0
}

$remoteScript = @'
set -euo pipefail

api_base_url=__API_BASE_URL__
api_client_id=__API_CLIENT_ID__
script_source_root=__SCRIPT_SOURCE_ROOT__
watcher_debounce_seconds='__WATCHER_DEBOUNCE__'
watcher_settle_seconds='__WATCHER_SETTLE__'

state_directory='/var/lib/linuxbroker-release-session'
output_directory='/usr/local/bin'
release_script="$output_directory/release-session.sh"
watcher_script="$output_directory/logind-session-watcher.sh"
xorg_script="$output_directory/xrdp-who-xorg.sh"
create_user_script="$output_directory/create-user.sh"
manage_lease_script="$output_directory/manage-lease.sh"
apply_settings_script="$output_directory/apply-host-settings.sh"
session_control_script="$output_directory/session-control.sh"
patch_host_script="$output_directory/patch-host.sh"
xrdp_startwm_script="$output_directory/xrdp-startwm.sh"
release_service_name='linuxbroker-release-session.service'
release_timer_name='linuxbroker-release-session.timer'
watcher_service_name='linuxbroker-release-session-watcher.service'
release_service_path="/etc/systemd/system/$release_service_name"
release_timer_path="/etc/systemd/system/$release_timer_name"
watcher_service_path="/etc/systemd/system/$watcher_service_name"
log_file='/var/log/release-session.log'
current_users_file="$state_directory/current_users.txt"
previous_users_file="$state_directory/previous_users.txt"
disconnected_users_file="$state_directory/disconnected_users.tsv"
sudoers_path='/etc/sudoers.d/avdadmin'

ensure_command() {
    local binary="$1"
    local package_name="$2"

    if command -v "$binary" >/dev/null 2>&1; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "$package_name"
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "$package_name"
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y "$package_name"
        return 0
    fi

    echo "Unable to install required command '$binary'."
    return 1
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$destination"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$url"
        return 0
    fi

    echo 'Neither curl nor wget is available for downloads.'
    return 1
}

# Earlier bootstraps installed xpra next to xrdp and opened TCP 443 for it, but the broker only
# ever connects through xrdp. Every step is best effort, so a host where one fails still gets the
# new agent. The repository definition goes first, because while xpra.org is unreachable it makes
# every dnf or yum command on the host fail.
remove_xpra() {
    local repo_file='/etc/yum.repos.d/xpra.repo'
    local unit packages rules output key
    local remove_status=0

    if [ -f "$repo_file" ]; then
        if rm -f "$repo_file"; then
            echo "Removed the xpra repository definition $repo_file."
        else
            echo "WARNING: Unable to remove $repo_file."
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        for unit in xpra.socket xpra-encoder.socket xpra.service xpra-encoder.service; do
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        done
    fi

    packages=''
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        packages=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E '^(python[0-9]*-)?xpra(-|$)' | sort -u | paste -sd ' ' - || true)
    elif command -v dpkg-query >/dev/null 2>&1; then
        packages=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
            | awk 'substr($1, 2, 1) != "n" && $2 ~ /^(python3-)?xpra(-|$)/ { print $2 }' | sort -u | paste -sd ' ' - || true)
    fi

    if [ -n "$packages" ]; then
        # Package names contain no spaces or glob characters, so the list is split unquoted.
        # Only xpra's own packages are removed. The libraries they pulled in stay, because a
        # user's own tools may rely on them without any installed package requiring them.
        # Run Command returns only the end of the output, so the transaction log is kept back
        # unless the removal fails.
        # shellcheck disable=SC2086
        if command -v dnf >/dev/null 2>&1; then
            output=$(dnf remove -y --noautoremove $packages 2>&1) || remove_status=$?
        elif command -v yum >/dev/null 2>&1; then
            output=$(yum remove -y $packages 2>&1) || remove_status=$?
        else
            output=$(DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 purge -y $packages 2>&1) || remove_status=$?
        fi
        if [ "$remove_status" -eq 0 ]; then
            echo "Removed the xpra packages: $packages."
        else
            echo "WARNING: Unable to remove the xpra packages ($packages); the package manager exited with $remove_status:"
            printf '%s\n' "$output" | tail -n 5
        fi
    fi

    # dnf imported xpra.org's signing key when it first installed xpra. Nothing needs it once the
    # repository is gone, and leaving it would keep trusting any package xpra.org signs.
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        for key in $(rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n' 2>/dev/null | awk '/xpra\.org/ { print $1 }' || true); do
            if rpm -e "$key" >/dev/null 2>&1; then
                echo "Removed the xpra.org package signing key $key."
            else
                echo "WARNING: Unable to remove the xpra.org package signing key $key."
            fi
        done
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --permanent --query-port=443/tcp >/dev/null 2>&1; then
            if firewall-cmd --permanent --remove-port=443/tcp >/dev/null && firewall-cmd --reload >/dev/null; then
                echo 'Closed TCP 443 in firewalld.'
            else
                echo 'WARNING: Unable to close TCP 443 in firewalld.'
            fi
        fi
    elif command -v ufw >/dev/null 2>&1; then
        rules=$(ufw show added 2>/dev/null || true)
        if grep -qx 'ufw allow 443/tcp' <<< "$rules"; then
            if ufw delete allow 443/tcp >/dev/null; then
                echo 'Closed TCP 443 in ufw.'
            else
                echo 'WARNING: Unable to close TCP 443 in ufw.'
            fi
        fi
    fi
}

# Called in an || list so that set -e cannot stop the migration partway through the cleanup.
remove_xpra || echo 'WARNING: The xpra cleanup did not finish.'

ensure_command curl curl
ensure_command jq jq
ensure_command dconf dconf || ensure_command dconf dconf-cli || echo 'dconf is unavailable; screen lock policy will be written but not compiled.'

# Idle session enforcement fails open without xprintidle, so this must not abort the run.
if ! command -v xprintidle >/dev/null 2>&1; then
    ensure_command xprintidle xprintidle || echo 'xprintidle is unavailable; idle session enforcement will be skipped on this host.'
fi

if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    echo 'Missing /etc/os-release. Unable to determine Linux distribution.'
    exit 1
fi

# One release agent serves every distribution.
release_script_url="$script_source_root/linux_host/session_release_buffer/release-session.sh"
xorg_script_url="$script_source_root/linux_host/session_release_buffer/xrdp-who-xorg.sh"
watcher_script_url="$script_source_root/linux_host/session_release_buffer/logind-session-watcher.sh"
create_user_script_url="$script_source_root/linux_host/create-user.sh"
manage_lease_script_url="$script_source_root/linux_host/manage-lease.sh"
apply_settings_script_url="$script_source_root/linux_host/apply-host-settings.sh"
session_control_script_url="$script_source_root/linux_host/session-control.sh"
patch_host_script_url="$script_source_root/linux_host/patch-host.sh"
xrdp_startwm_script_url="$script_source_root/linux_host/xrdp-startwm.sh"

mkdir -p "$output_directory" "$state_directory" "$state_directory/leases"

download_file "$release_script_url" "$release_script"
download_file "$xorg_script_url" "$xorg_script"
download_file "$watcher_script_url" "$watcher_script"
download_file "$create_user_script_url" "$create_user_script"
download_file "$manage_lease_script_url" "$manage_lease_script"
download_file "$apply_settings_script_url" "$apply_settings_script"
download_file "$session_control_script_url" "$session_control_script"
download_file "$patch_host_script_url" "$patch_host_script"
download_file "$xrdp_startwm_script_url" "$xrdp_startwm_script"

chmod +x "$release_script" "$xorg_script" "$watcher_script" "$create_user_script" "$manage_lease_script" "$apply_settings_script" "$session_control_script" "$patch_host_script" "$xrdp_startwm_script"

sed -i "s|YOUR_LINUX_BROKER_API_CLIENT_ID|$api_client_id|g" "$release_script"
sed -i "s|YOUR_LINUX_BROKER_API_BASE_URL|$api_base_url|g" "$release_script"
sed -i "s|YOUR_LINUX_BROKER_API_URL|$api_base_url|g" "$release_script"

touch "$log_file" "$current_users_file" "$previous_users_file" "$disconnected_users_file"
chmod 600 "$log_file" "$current_users_file" "$previous_users_file" "$disconnected_users_file"

if ! id avdadmin >/dev/null 2>&1; then
    useradd avdadmin
fi

# Only the commands the broker API actually invokes with sudo. Privileged file work
# (mount, chown, chmod, lease markers, host settings) happens inside the allowlisted
# scripts, each of which validates its own input.
sudoers_commands=()
for command_name in userdel groupadd usermod chpasswd; do
    resolved_command=$(command -v "$command_name" || true)
    if [ -n "$resolved_command" ]; then
        sudoers_commands+=("$resolved_command")
    fi
done
sudoers_commands+=("$create_user_script" "$manage_lease_script" "$apply_settings_script" "$session_control_script" "$patch_host_script")

sudoers_tmp="${sudoers_path}.tmp"
(
    IFS=,
    printf 'avdadmin ALL=(ALL) NOPASSWD: %s\n' "${sudoers_commands[*]}" > "$sudoers_tmp"
)
chmod 440 "$sudoers_tmp"
if visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
    mv "$sudoers_tmp" "$sudoers_path"
else
    rm -f "$sudoers_tmp"
    echo 'Generated sudoers policy failed validation.'
    exit 1
fi

if command -v crontab >/dev/null 2>&1; then
    tmp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v -F "$release_script" > "$tmp_cron" || true
    if [ -s "$tmp_cron" ]; then
        crontab "$tmp_cron"
    else
        crontab -r 2>/dev/null || true
    fi
    rm -f "$tmp_cron"
fi

if command -v pkill >/dev/null 2>&1; then
    pkill -f "$release_script" || true
fi

cat <<EOF > "$release_service_path"
[Unit]
Description=Linux Broker Release Agent
After=network-online.target xrdp.service
Wants=network-online.target
ConditionPathExists=$release_script

[Service]
Type=oneshot
User=root
WorkingDirectory=$state_directory
ExecStart=$release_script --systemd-timer
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > "$release_timer_path"
[Unit]
Description=Run Linux Broker Release Agent every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true
Unit=$release_service_name

[Install]
WantedBy=timers.target
EOF

cat <<EOF > "$watcher_service_path"
[Unit]
Description=Linux Broker logind Session Watcher
After=network-online.target systemd-logind.service
Wants=network-online.target
ConditionPathExists=$watcher_script

[Service]
Type=simple
User=root
WorkingDirectory=$state_directory
Environment=LINUXBROKER_LOGIND_WATCHER_DEBOUNCE_SECONDS=$watcher_debounce_seconds
Environment=LINUXBROKER_LOGIND_WATCHER_SETTLE_SECONDS=$watcher_settle_seconds
ExecStart=$watcher_script
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if [ -x "$apply_settings_script" ]; then
    # Only seed when the host has no profile yet. Re-seeding would reset a host that already
    # converged to the configured profile, until its next reconcile run pulled it back.
    if [ -f /etc/linuxbroker/host-settings.conf ]; then
        echo 'Existing Linux Broker host settings found. Leaving them in place.'
    elif "$apply_settings_script" --defaults; then
        echo 'Seeded default Linux Broker host settings.'
    else
        echo 'WARNING: Failed to seed default Linux Broker host settings.'
    fi
fi

# xrdp starts every session through xrdp-startwm.sh. Until the host bootstrap names a desktop
# in /etc/linuxbroker/desktop.conf, it runs the distribution's session script as before.
launcher_status=0
"$xrdp_startwm_script" --install || launcher_status=$?
if [ "$launcher_status" -ne 0 ] && [ "$launcher_status" -ne 3 ]; then
    echo "WARNING: xrdp-startwm.sh --install failed with exit code $launcher_status."
fi

systemctl disable --now "$watcher_service_name" >/dev/null 2>&1 || true
systemctl disable --now "$release_timer_name" >/dev/null 2>&1 || true
systemctl disable --now "$release_service_name" >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl reset-failed "$release_service_name" >/dev/null 2>&1 || true
systemctl reset-failed "$watcher_service_name" >/dev/null 2>&1 || true
systemctl enable --now "$release_timer_name"
systemctl enable --now "$watcher_service_name"
systemctl start "$release_service_name"

printf 'Migrated release agent on %s\n' "$(hostname)"
printf 'Release service: %s\n' "$(systemctl is-active "$release_service_name" || true)"
printf 'Release timer: %s / %s\n' "$(systemctl is-enabled "$release_timer_name" || true)" "$(systemctl is-active "$release_timer_name" || true)"
printf 'Watcher service: %s / %s\n' "$(systemctl is-enabled "$watcher_service_name" || true)" "$(systemctl is-active "$watcher_service_name" || true)"
'@

$remoteScript = $remoteScript.Replace('__API_BASE_URL__', (ConvertTo-BashSingleQuotedLiteral -Value $ApiBaseUrl))
$remoteScript = $remoteScript.Replace('__API_CLIENT_ID__', (ConvertTo-BashSingleQuotedLiteral -Value $ApiClientId))
$remoteScript = $remoteScript.Replace('__SCRIPT_SOURCE_ROOT__', (ConvertTo-BashSingleQuotedLiteral -Value $ScriptSourceRoot))
$remoteScript = $remoteScript.Replace('__WATCHER_DEBOUNCE__', $WatcherDebounceSeconds.ToString())
$remoteScript = $remoteScript.Replace('__WATCHER_SETTLE__', $WatcherSettleSeconds.ToString())

# One host that is off or failing must not leave the rest of the fleet on the old agent, so
# every host is attempted and the failures are reported together at the end.
$failures = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

foreach ($linuxHost in $linuxHosts) {
    $powerProperty = $linuxHost.PSObject.Properties['powerState']
    $powerState = if ($powerProperty) { [string]$powerProperty.Value } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($powerState) -and $powerState -notmatch 'running') {
        Write-Warning "Skipping Linux host '$($linuxHost.name)' because it is not running ($powerState). Start it and run this script again with -LinuxHostNames $($linuxHost.name)."
        $skipped.Add($linuxHost.name)
        continue
    }

    Write-Host "Migrating Linux host '$($linuxHost.name)'..."
    try {
        $message = Invoke-RunCommandWithRetry -VmName $linuxHost.name -Script $remoteScript
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            Write-Host $message
        }
        # Run Command reports success whatever the script did, so the script's own closing line
        # is the only evidence that it ran to the end.
        if ($message -notmatch 'Migrated release agent on') {
            throw "The migration script did not run to completion on '$($linuxHost.name)'."
        }
    }
    catch {
        Write-Warning $_.Exception.Message
        $failures.Add($linuxHost.name)
    }
}

if ($skipped.Count -gt 0) {
    Write-Warning "Not migrated because they are not running: $($skipped -join ', ')."
}

if ($failures.Count -gt 0) {
    throw "Linux host migration failed on: $($failures -join ', '). Rerun with -LinuxHostNames to retry them."
}