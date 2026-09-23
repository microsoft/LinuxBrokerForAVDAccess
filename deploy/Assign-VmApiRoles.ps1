[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$AvdHostGroupId,

    [Parameter(Mandatory = $false)]
    [string]$LinuxHostGroupId,

    [Parameter(Mandatory = $false)]
    [string]$EnvironmentName
)

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

function Ensure-GroupMembership {
    param(
        [Parameter(Mandatory = $true)][string]$GroupId,
        [Parameter(Mandatory = $true)][string]$PrincipalId,
        [Parameter(Mandatory = $true)][string]$VmName
    )

    # A new VM identity can take a short time to replicate in Microsoft Entra ID,
    # so keep retrying until the membership is confirmed.
    $maxAttempts = 6
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $isMember = az ad group member check --group $GroupId --member-id $PrincipalId --query value --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and "$isMember".Trim() -eq 'true') {
            if ($attempt -eq 1) {
                Write-Host "VM '$VmName' managed identity is already a member of group '$GroupId'."
            }
            else {
                Write-Host "Added VM '$VmName' managed identity to group '$GroupId'."
            }

            return
        }

        az ad group member add --group $GroupId --member-id $PrincipalId 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Attempt $attempt of $maxAttempts to add VM '$VmName' managed identity to group '$GroupId' failed."
        }

        Start-Sleep -Seconds (10 * $attempt)
    }

    throw "Unable to confirm that VM '$VmName' managed identity is a member of group '$GroupId'. Re-run 'azd hooks run postprovision' after checking Microsoft Entra ID."
}

if ([string]::IsNullOrWhiteSpace($AvdHostGroupId)) {
    $AvdHostGroupId = Get-AzdEnvValue -Key 'avdHostGroupId'
    if ([string]::IsNullOrWhiteSpace($AvdHostGroupId)) {
        $AvdHostGroupId = Get-AzdEnvValue -Key 'AVD_HOST_GROUP_ID'
    }
}

if ([string]::IsNullOrWhiteSpace($LinuxHostGroupId)) {
    $LinuxHostGroupId = Get-AzdEnvValue -Key 'linuxHostGroupId'
    if ([string]::IsNullOrWhiteSpace($LinuxHostGroupId)) {
        $LinuxHostGroupId = Get-AzdEnvValue -Key 'LINUX_HOST_GROUP_ID'
    }
}

$virtualMachines = az vm list --resource-group $ResourceGroupName --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list virtual machines in resource group '$ResourceGroupName'."
}

if (-not $virtualMachines) {
    Write-Host "No virtual machines found in resource group '$ResourceGroupName'."
    exit 0
}

$groupMappings = @(
    @{ Tag = 'linux-host'; GroupId = $LinuxHostGroupId }
    @{ Tag = 'avd-host'; GroupId = $AvdHostGroupId }
)

foreach ($mapping in $groupMappings) {
    if ([string]::IsNullOrWhiteSpace($mapping.GroupId)) {
        Write-Warning "Skipping '$($mapping.Tag)' VMs because no group id was provided."
        continue
    }

    $matchingVms = $virtualMachines | Where-Object { $_.tags.'broker-role' -eq $mapping.Tag }
    foreach ($virtualMachine in $matchingVms) {
        $principalId = az vm show --resource-group $ResourceGroupName --name $virtualMachine.name --query identity.principalId --output tsv
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read the managed identity of VM '$($virtualMachine.name)'."
        }

        if ([string]::IsNullOrWhiteSpace($principalId)) {
            Write-Warning "Skipping VM '$($virtualMachine.name)' because no managed identity principal id was found."
            continue
        }

        Ensure-GroupMembership -GroupId $mapping.GroupId -PrincipalId $principalId -VmName $virtualMachine.name
    }
}
