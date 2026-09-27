<#
.SYNOPSIS
    Connects the Linux hosts and the AVD session hosts to the host monitoring.

.DESCRIPTION
    With deployHostMonitoring on, the deployment creates two data collection rules: one that
    collects the broker's logs, the xrdp logs and syslog from the Linux hosts, and one that
    collects the Connect-LinuxBroker.ps1 events and Remote Desktop client problems from the AVD
    session hosts. The deployment cannot install the Azure Monitor agent itself, because Azure
    refuses to add an extension to a VM that is not running, and scaling powers hosts off.

    This script associates every VM tagged broker-role=linux-host with the Linux rule and every
    VM tagged broker-role=avd-host with the AVD rule, which works whether the VM is running or
    not. It then installs the Azure Monitor agent, with automatic upgrades, on each running VM
    that does not have it yet, and waits for the installs to finish.

    A VM that is not running keeps its association but gets no agent, so it sends nothing: start
    it and run this script again, with -HostNames to limit the run to it. Every host is
    attempted, and the ones that failed are reported together at the end, with a non-zero exit
    code. Running the script again is safe.

    Values that are not given are read from the azd environment. When the deployment has no host
    monitoring, the script says so and changes nothing.

.EXAMPLE
    .\Enable-HostMonitoring.ps1 -EnvironmentName <environment-name>

.EXAMPLE
    .\Enable-HostMonitoring.ps1 -EnvironmentName <environment-name> -HostNames <host-name>, <host-name>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [string]$LinuxHostDataCollectionRuleId,

    [Parameter(Mandatory = $false)]
    [string]$AvdHostDataCollectionRuleId,

    [Parameter(Mandatory = $false)]
    [string[]]$HostNames,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 120)]
    [int]$AgentTimeoutMinutes = 20
)

# One association per VM under a fixed name, so running the script again replaces it.
$AssociationName = 'linuxbroker-host-monitoring'
$AgentPollSeconds = 30

# Runs az, keeping what it writes to standard output apart from its error lines. The error lines
# must not stop the script, whatever the caller's preference.
function Invoke-AzCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $callerErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(az @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $callerErrorActionPreference
    }

    $standardOutput = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    $errorOutput = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($standardOutput -join "`n").Trim()
        Error    = ($errorOutput -join ' ').Trim()
    }
}

function Get-AzdEnvValue {
    param(
        [AllowEmptyString()]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        return ''
    }

    # azd reports a value it does not have on stderr, which must not stop the script.
    $callerErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $value = azd env get-value $Key --environment $EnvironmentName 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $callerErrorActionPreference
    }

    if ($exitCode -ne 0) {
        return ''
    }

    return ($value | Out-String).Trim()
}

# A property's value, or $null when the object or the property is missing, which StrictMode
# would otherwise refuse.
function Get-PropertyValue {
    param(
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-VmTagValue {
    param(
        [Parameter(Mandatory = $true)]
        $Vm,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $Vm -Name 'tags') -Name $Name)
}

function Test-DataCollectionRuleId {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    return $Value -match '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/\s]+/providers/Microsoft\.Insights/dataCollectionRules/[^/\s]+\z'
}

function Set-DataCollectionRuleAssociation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmId,

        [Parameter(Mandatory = $true)]
        [string]$RuleId
    )

    $body = ConvertTo-Json -Compress -InputObject ([ordered]@{
            properties = [ordered]@{
                description          = 'Linux Broker host monitoring, from deploy/Enable-HostMonitoring.ps1.'
                dataCollectionRuleId = $RuleId
            }
        })

    # The body reaches az as @file: on Windows az runs through az.cmd, where cmd.exe would take
    # the quotes in inline JSON for its own.
    $bodyFile = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('linuxbroker-dcra-{0}.json' -f [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding -ArgumentList $false))
    try {
        # A URL without a host is a resource ID on the current cloud's Resource Manager. The API
        # version goes in --url-parameters, because az.cmd would hand an unquoted & to cmd.exe.
        $result = Invoke-AzCommand -Arguments @(
            'rest', '--method', 'put',
            '--url', "$VmId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$AssociationName",
            '--url-parameters', 'api-version=2022-06-01',
            '--body', "@$bodyFile",
            '--output', 'none', '--only-show-errors')
    }
    finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }

    if ($result.ExitCode -ne 0) {
        throw ("Could not associate the data collection rule. {0}" -f $result.Error).Trim()
    }
}

# An extension property, which az lists flattened; a nested properties object is read as well.
# NestedNames are read only from the nested object, where 'type' is the extension's type rather
# than the resource type it is at the top level.
function Get-ExtensionPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $Extension,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [string[]]$NestedNames = @()
    )

    $properties = Get-PropertyValue -InputObject $Extension -Name 'properties'
    $candidates = @($Names | ForEach-Object { [pscustomobject]@{ Source = $Extension; Name = $_ } }) +
        @(($Names + $NestedNames) | ForEach-Object { [pscustomobject]@{ Source = $properties; Name = $_ } })
    foreach ($candidate in $candidates) {
        $value = [string](Get-PropertyValue -InputObject $candidate.Source -Name $candidate.Name)
        if ($value.Length -gt 0) {
            return $value
        }
    }

    return ''
}

# The agent's extension on the VM, as its instance name and provisioning state, or $null when the
# VM has none. Azure allows one extension of each type on a VM, and the portal or a policy may
# have installed the agent under another name, so the type counts as well as the name.
function Get-AgentExtension {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$AgentName
    )

    $result = Invoke-AzCommand -Arguments @('vm', 'extension', 'list', '--resource-group', $ResourceGroupName, '--vm-name', $VmName, '--output', 'json', '--only-show-errors')
    if ($result.ExitCode -ne 0) {
        throw ("Could not list the extensions of '{0}'. {1}" -f $VmName, $result.Error).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return $null
    }

    foreach ($extension in @(ConvertFrom-Json -InputObject $result.Output | ForEach-Object { $_ })) {
        $name = [string](Get-PropertyValue -InputObject $extension -Name 'name')
        # Older versions of az call the type virtualMachineExtensionType.
        $type = Get-ExtensionPropertyValue -Extension $extension -Names @('typePropertiesType', 'virtualMachineExtensionType') -NestedNames @('type')
        $publisher = Get-ExtensionPropertyValue -Extension $extension -Names @('publisher')
        if ($name -eq $AgentName -or ($type -eq $AgentName -and $publisher -eq 'Microsoft.Azure.Monitor')) {
            return [pscustomobject]@{
                Name              = $name
                ProvisioningState = Get-ExtensionPropertyValue -Extension $extension -Names @('provisioningState')
            }
        }
    }

    return $null
}

function Start-AgentInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$AgentName,

        [Parameter(Mandatory = $true)]
        [string]$InstanceName,

        # An extension that failed runs again only when forced, as its settings are unchanged.
        [switch]$Reinstall
    )

    # The agent authenticates with the VM's system-assigned identity, which needs no settings.
    $arguments = @(
        'vm', 'extension', 'set',
        '--resource-group', $ResourceGroupName,
        '--vm-name', $VmName,
        '--name', $AgentName,
        '--publisher', 'Microsoft.Azure.Monitor',
        '--extension-instance-name', $InstanceName,
        '--enable-auto-upgrade', 'true')
    if ($Reinstall) {
        $arguments += '--force-update'
    }

    $result = Invoke-AzCommand -Arguments ($arguments + @('--no-wait', '--output', 'none', '--only-show-errors'))
    if ($result.ExitCode -ne 0) {
        throw ("Could not start installing the Azure Monitor agent. {0}" -f $result.Error).Trim()
    }
}

function Invoke-HostMonitoringSetup {
    param(
        [string]$ResourceGroupName,
        [string]$SubscriptionId,
        [string]$EnvironmentName,
        [string]$LinuxHostDataCollectionRuleId,
        [string]$AvdHostDataCollectionRuleId,
        [string[]]$HostNames,
        [ValidateRange(1, 120)]
        [int]$AgentTimeoutMinutes = 20
    )

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

    if ([string]::IsNullOrWhiteSpace($LinuxHostDataCollectionRuleId)) {
        $LinuxHostDataCollectionRuleId = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'linuxHostDataCollectionRuleId'
    }

    if ([string]::IsNullOrWhiteSpace($AvdHostDataCollectionRuleId)) {
        $AvdHostDataCollectionRuleId = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'avdHostDataCollectionRuleId'
    }

    $LinuxHostDataCollectionRuleId = ([string]$LinuxHostDataCollectionRuleId).Trim()
    $AvdHostDataCollectionRuleId = ([string]$AvdHostDataCollectionRuleId).Trim()
    if ($LinuxHostDataCollectionRuleId.Length -eq 0 -and $AvdHostDataCollectionRuleId.Length -eq 0) {
        Write-Host 'This deployment has no host monitoring, so there is nothing to connect: deployHostMonitoring is false, or azd provision has not run since the monitoring was added.'
        return
    }

    foreach ($ruleId in @($LinuxHostDataCollectionRuleId, $AvdHostDataCollectionRuleId)) {
        if ($ruleId.Length -gt 0 -and -not (Test-DataCollectionRuleId -Value $ruleId)) {
            throw "'$ruleId' is not the resource ID of a data collection rule, such as /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/dataCollectionRules/<name>."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        $ResourceGroupName = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'resourceGroupName'
    }

    if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
        throw 'The host monitoring setup needs ResourceGroupName, as a parameter or an azd environment value.'
    }

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId = Get-AzdEnvValue -EnvironmentName $EnvironmentName -Key 'AZURE_SUBSCRIPTION_ID'
    }

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
    }

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        $result = Invoke-AzCommand -Arguments @('account', 'set', '--subscription', $SubscriptionId)
        if ($result.ExitCode -ne 0) {
            throw "Could not select subscription '$SubscriptionId'."
        }
    }

    $roles = @{
        'linux-host' = [pscustomobject]@{ Label = 'Linux host'; RuleId = $LinuxHostDataCollectionRuleId; Agent = 'AzureMonitorLinuxAgent' }
        'avd-host'   = [pscustomobject]@{ Label = 'AVD session host'; RuleId = $AvdHostDataCollectionRuleId; Agent = 'AzureMonitorWindowsAgent' }
    }

    $result = Invoke-AzCommand -Arguments @('vm', 'list', '--resource-group', $ResourceGroupName, '--show-details', '--output', 'json', '--only-show-errors')
    if ($result.ExitCode -ne 0) {
        throw "Could not list the VMs in resource group '$ResourceGroupName'. $($result.Error)".Trim()
    }

    $vms = @()
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $vms = @(ConvertFrom-Json -InputObject $result.Output | ForEach-Object { $_ })
    }

    $hosts = @($vms | Where-Object {
            $vmRole = Get-VmTagValue -Vm $_ -Name 'broker-role'
            $roles.ContainsKey($vmRole) -and $roles[$vmRole].RuleId.Length -gt 0
        })

    if ($HostNames -and $HostNames.Count -gt 0) {
        $requestedNames = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $HostNames) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                [void]$requestedNames.Add($name.Trim())
            }
        }

        $filteredHosts = @($hosts | Where-Object { $requestedNames.Contains([string]$_.name) })
        foreach ($name in $requestedNames) {
            if (-not ($filteredHosts | Where-Object { $_.name -eq $name })) {
                Write-Warning "Requested host '$name' is not a Linux host or AVD session host in resource group '$ResourceGroupName'."
            }
        }

        $hosts = $filteredHosts
    }

    if ($hosts.Count -eq 0) {
        Write-Host "No Linux hosts or AVD session hosts to connect to the host monitoring in resource group '$ResourceGroupName'."
        return
    }

    # One host that is off or failing must not leave the rest unmonitored, so every one is
    # attempted and the failures are reported together at the end.
    $connected = New-Object System.Collections.Generic.List[string]
    $notRunning = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[string]
    $installing = New-Object System.Collections.Generic.List[object]

    foreach ($vm in $hosts) {
        $name = [string]$vm.name
        $role = $roles[(Get-VmTagValue -Vm $vm -Name 'broker-role')]
        try {
            Set-DataCollectionRuleAssociation -VmId ([string]$vm.id) -RuleId $role.RuleId
        }
        catch {
            Write-Warning "Could not connect $($role.Label) '$name' to the host monitoring: $($_.Exception.Message)"
            $failures.Add($name)
            continue
        }

        $powerState = [string](Get-PropertyValue -InputObject $vm -Name 'powerState')
        if (-not [string]::IsNullOrWhiteSpace($powerState) -and $powerState -notmatch 'running') {
            Write-Warning "$($role.Label) '$name' is connected, but it is not running ($powerState), so it has no Azure Monitor agent and sends no logs yet."
            $notRunning.Add($name)
            continue
        }

        try {
            $extension = Get-AgentExtension -ResourceGroupName $ResourceGroupName -VmName $name -AgentName $role.Agent
            $state = if ($null -ne $extension) { $extension.ProvisioningState } else { '' }
            if ($state -eq 'Succeeded') {
                Write-Host "$($role.Label) '$name' is connected, and already has the Azure Monitor agent."
                $connected.Add($name)
                continue
            }

            # An install that is under way is waited for rather than started again.
            if ($state -ne 'Creating' -and $state -ne 'Updating') {
                $instanceName = if ($null -ne $extension -and $extension.Name.Length -gt 0) { $extension.Name } else { $role.Agent }
                Write-Host "Installing the Azure Monitor agent on $($role.Label) '$name'..."
                Start-AgentInstall -ResourceGroupName $ResourceGroupName -VmName $name -AgentName $role.Agent -InstanceName $instanceName -Reinstall:($null -ne $extension)
            }

            $installing.Add([pscustomobject]@{ Name = $name; Role = $role })
        }
        catch {
            Write-Warning "Could not install the Azure Monitor agent on $($role.Label) '$name': $($_.Exception.Message)"
            $failures.Add($name)
        }
    }

    # The installs run side by side. A poll that cannot read a VM's extensions is retried at the
    # next one.
    $pollsLeft = [int][Math]::Ceiling(($AgentTimeoutMinutes * 60) / $AgentPollSeconds)
    while ($installing.Count -gt 0 -and $pollsLeft -gt 0) {
        $pollsLeft--
        Start-Sleep -Seconds $AgentPollSeconds
        foreach ($install in $installing.ToArray()) {
            try {
                $extension = Get-AgentExtension -ResourceGroupName $ResourceGroupName -VmName $install.Name -AgentName $install.Role.Agent
            }
            catch {
                continue
            }

            $state = if ($null -ne $extension) { $extension.ProvisioningState } else { '' }
            if ($state -eq 'Succeeded') {
                Write-Host "$($install.Role.Label) '$($install.Name)' is connected, with the Azure Monitor agent installed."
                $connected.Add($install.Name)
                [void]$installing.Remove($install)
            }
            elseif ($state -eq 'Failed') {
                Write-Warning "The Azure Monitor agent failed to install on $($install.Role.Label) '$($install.Name)'. The $($install.Role.Agent) extension's status on the VM says why."
                $failures.Add($install.Name)
                [void]$installing.Remove($install)
            }
        }
    }

    foreach ($install in $installing) {
        Write-Warning "The Azure Monitor agent install on $($install.Role.Label) '$($install.Name)' did not finish within $AgentTimeoutMinutes minute(s)."
        $failures.Add($install.Name)
    }

    if ($notRunning.Count -gt 0) {
        Write-Warning "No Azure Monitor agent yet because they are not running: $($notRunning -join ', '). Once they are running, run Enable-HostMonitoring.ps1 again with -HostNames $($notRunning -join ',')."
    }

    if ($failures.Count -gt 0) {
        throw "The host monitoring could not be set up on: $($failures -join ', '). Run Enable-HostMonitoring.ps1 again with -HostNames $($failures -join ',') to retry them."
    }

    Write-Host "The host monitoring is set up on $($connected.Count) host(s)."
}

# Dot-sourcing the script, as its tests do, defines the functions without changing anything.
if ($MyInvocation.InvocationName -ne '.') {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Invoke-HostMonitoringSetup `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -EnvironmentName $EnvironmentName `
        -LinuxHostDataCollectionRuleId $LinuxHostDataCollectionRuleId `
        -AvdHostDataCollectionRuleId $AvdHostDataCollectionRuleId `
        -HostNames $HostNames `
        -AgentTimeoutMinutes $AgentTimeoutMinutes
}
